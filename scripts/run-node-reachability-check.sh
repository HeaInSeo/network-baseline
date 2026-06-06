#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-node-reachability-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-node-to-node-reachability}"
PING_COUNT="${PING_COUNT:-3}"
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-5}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

cleanup_daemonset() {
  if [[ "${KEEP_NODE_REACHABILITY_PODS:-0}" != "1" ]]; then
    kubectl -n "${NAMESPACE}" delete daemonset network-health-node-reachability --ignore-not-found >/dev/null 2>&1 || true
  fi
}

need_cmd kubectl
need_cmd python3

mkdir -p "${ARTIFACT_DIR}"

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
result_json="${ARTIFACT_DIR}/${SCENARIO}.result.json"
pod_snapshot="${ARTIFACT_DIR}/${SCENARIO}.pods.json"
raw_log="${ARTIFACT_DIR}/${SCENARIO}.log"

trap cleanup_daemonset EXIT
kubectl -n "${NAMESPACE}" apply -f "${ROOT_DIR}/deploy/checks/node-reachability-daemonset.yaml"
kubectl -n "${NAMESPACE}" rollout status daemonset/network-health-node-reachability --timeout=120s
kubectl -n "${NAMESPACE}" get pods \
  -l app.kubernetes.io/name=network-baseline,app.kubernetes.io/component=node-reachability-check \
  -o json >"${pod_snapshot}"

python3 - <<PY
import json
from pathlib import Path

pods = json.loads(Path("${pod_snapshot}").read_text(encoding="utf-8")).get("items", [])
ready = []
for pod in pods:
    phase = pod.get("status", {}).get("phase", "")
    ip = pod.get("status", {}).get("podIP", "")
    node = pod.get("spec", {}).get("nodeName", "")
    name = pod.get("metadata", {}).get("name", "")
    if phase == "Running" and ip and node and name:
        ready.append({"name": name, "podIP": ip, "node": node})
Path("${ARTIFACT_DIR}/${SCENARIO}.ready-pods.json").write_text(json.dumps(ready, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

ready_count="$(python3 - <<PY
import json
from pathlib import Path
print(len(json.loads(Path("${ARTIFACT_DIR}/${SCENARIO}.ready-pods.json").read_text(encoding="utf-8"))))
PY
)"

if [[ "${ready_count}" -lt 2 ]]; then
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - <<PY
import json
from pathlib import Path

pods = json.loads(Path("${ARTIFACT_DIR}/${SCENARIO}.ready-pods.json").read_text(encoding="utf-8"))
result = {
    "schemaVersion": "network-baseline.health.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
        "nodeCount": len(pods),
        "pods": pods,
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "node-to-node-reachability",
        "pingCount": int("${PING_COUNT}"),
        "pingTimeoutSeconds": int("${PING_TIMEOUT_SECONDS}"),
    },
    "status": "skipped",
    "reasons": ["node-to-node reachability requires at least two ready check pods"],
    "rawLogPath": "${raw_log}",
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print("${SCENARIO}: skipped readyPods=" + str(len(pods)))
PY
  echo "result: ${result_json}"
  exit 0
fi

python3 - <<PY >"${ARTIFACT_DIR}/${SCENARIO}.pairs.tsv"
import json
from pathlib import Path

pods = json.loads(Path("${ARTIFACT_DIR}/${SCENARIO}.ready-pods.json").read_text(encoding="utf-8"))
for src in pods:
    for dst in pods:
        if src["name"] == dst["name"]:
            continue
        print("\t".join([src["name"], src["node"], dst["name"], dst["node"], dst["podIP"]]))
PY

: >"${raw_log}"
while IFS=$'\t' read -r src_pod src_node dst_pod dst_node dst_ip; do
  echo "src=${src_pod} srcNode=${src_node} dst=${dst_pod} dstNode=${dst_node} dstIP=${dst_ip}" >>"${raw_log}"
  set +e
  kubectl -n "${NAMESPACE}" exec "${src_pod}" -- ping -c "${PING_COUNT}" -W "${PING_TIMEOUT_SECONDS}" "${dst_ip}" >>"${raw_log}" 2>&1
  rc="$?"
  set -e
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "${src_pod}" "${src_node}" "${dst_pod}" "${dst_node}" "${dst_ip}" "${rc}" >>"${ARTIFACT_DIR}/${SCENARIO}.pairs.result.tsv"
done <"${ARTIFACT_DIR}/${SCENARIO}.pairs.tsv"

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - <<PY
import json
from pathlib import Path

pods = json.loads(Path("${ARTIFACT_DIR}/${SCENARIO}.ready-pods.json").read_text(encoding="utf-8"))
pairs = []
result_path = Path("${ARTIFACT_DIR}/${SCENARIO}.pairs.result.tsv")
if result_path.exists():
    for line in result_path.read_text(encoding="utf-8").splitlines():
        src_pod, src_node, dst_pod, dst_node, dst_ip, rc = line.split("\t")
        pairs.append({
            "sourcePod": src_pod,
            "sourceNode": src_node,
            "targetPod": dst_pod,
            "targetNode": dst_node,
            "targetPodIP": dst_ip,
            "status": "pass" if rc == "0" else "fail",
            "exitCode": int(rc),
        })
status = "pass"
reasons = []
failed = [pair for pair in pairs if pair["status"] == "fail"]
if failed:
    status = "fail"
    reasons.append("one or more node-to-node ping checks failed")
result = {
    "schemaVersion": "network-baseline.health.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
        "nodeCount": len({pod["node"] for pod in pods}),
        "pods": pods,
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "node-to-node-reachability",
        "pingCount": int("${PING_COUNT}"),
        "pingTimeoutSeconds": int("${PING_TIMEOUT_SECONDS}"),
    },
    "checks": pairs,
    "status": status,
    "reasons": reasons,
    "rawLogPath": "${raw_log}",
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"${SCENARIO}: {status} pairs={len(pairs)}")
PY

echo "result: ${result_json}"
