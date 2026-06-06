#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-conntrack-snapshot-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-conntrack-snapshot}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

cleanup_daemonset() {
  if [[ "${KEEP_CONNTRACK_SNAPSHOT_PODS:-0}" != "1" ]]; then
    kubectl -n "${NAMESPACE}" delete daemonset network-health-conntrack-snapshot --ignore-not-found >/dev/null 2>&1 || true
  fi
}

need_cmd kubectl
need_cmd python3

mkdir -p "${ARTIFACT_DIR}"

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
result_json="${ARTIFACT_DIR}/${SCENARIO}.result.json"
pod_snapshot="${ARTIFACT_DIR}/${SCENARIO}.pods.json"
raw_dir="${ARTIFACT_DIR}/${SCENARIO}.raw"

mkdir -p "${raw_dir}"

trap cleanup_daemonset EXIT
kubectl -n "${NAMESPACE}" apply -f "${ROOT_DIR}/deploy/checks/conntrack-snapshot-daemonset.yaml"
kubectl -n "${NAMESPACE}" rollout status daemonset/network-health-conntrack-snapshot --timeout=120s
kubectl -n "${NAMESPACE}" get pods \
  -l app.kubernetes.io/name=network-baseline,app.kubernetes.io/component=conntrack-snapshot \
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
    if phase == "Running" and node and name:
        ready.append({"name": name, "podIP": ip, "node": node})
Path("${ARTIFACT_DIR}/${SCENARIO}.ready-pods.json").write_text(json.dumps(ready, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 - <<PY >"${ARTIFACT_DIR}/${SCENARIO}.pods.tsv"
import json
from pathlib import Path

pods = json.loads(Path("${ARTIFACT_DIR}/${SCENARIO}.ready-pods.json").read_text(encoding="utf-8"))
for pod in pods:
    print(pod["name"] + "\t" + pod["node"])
PY

while IFS=$'\t' read -r pod node; do
  safe_node="${node//[^A-Za-z0-9_.-]/-}"
  raw_log="${raw_dir}/${safe_node}.log"
  kubectl -n "${NAMESPACE}" exec "${pod}" -- sh -ceu '
    for path in \
      /host/proc/sys/net/netfilter/nf_conntrack_count \
      /host/proc/sys/net/netfilter/nf_conntrack_max \
      /host/proc/sys/net/netfilter/nf_conntrack_buckets \
      /host/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established
    do
      printf "file=%s value=" "$path"
      cat "$path" 2>/dev/null || true
      printf "\n"
    done
    if [ -f /host/proc/net/stat/nf_conntrack ]; then
      echo "file=/host/proc/net/stat/nf_conntrack present=true"
      head -n 3 /host/proc/net/stat/nf_conntrack || true
    else
      echo "file=/host/proc/net/stat/nf_conntrack present=false"
    fi
  ' >"${raw_log}" 2>&1 || true
done <"${ARTIFACT_DIR}/${SCENARIO}.pods.tsv"

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - <<PY
import json
import re
from pathlib import Path

raw_dir = Path("${raw_dir}")
pods = json.loads(Path("${ARTIFACT_DIR}/${SCENARIO}.ready-pods.json").read_text(encoding="utf-8"))
nodes = []
status = "pass"
reasons = []

def parse_value(raw, path):
    pattern = re.compile(r"^file=" + re.escape(path) + r" value=(.*)$", re.MULTILINE)
    match = pattern.search(raw)
    if not match:
        return None
    value = match.group(1).strip()
    if not value:
        return None
    try:
        return int(value)
    except ValueError:
        return None

for pod in pods:
    node = pod["node"]
    safe_node = re.sub(r"[^A-Za-z0-9_.-]", "-", node)
    raw_path = raw_dir / f"{safe_node}.log"
    raw = raw_path.read_text(encoding="utf-8", errors="replace") if raw_path.exists() else ""
    count = parse_value(raw, "/host/proc/sys/net/netfilter/nf_conntrack_count")
    max_value = parse_value(raw, "/host/proc/sys/net/netfilter/nf_conntrack_max")
    usage_percent = None
    node_status = "pass"
    node_reasons = []
    if count is None or max_value is None:
        node_status = "warn"
        node_reasons.append("conntrack count/max was not readable")
    elif max_value > 0:
        usage_percent = (count / max_value) * 100
        if usage_percent >= 90:
            node_status = "fail"
            node_reasons.append("conntrack usage is at or above 90 percent")
        elif usage_percent >= 70:
            node_status = "warn"
            node_reasons.append("conntrack usage is at or above 70 percent")
    nodes.append({
        "node": node,
        "pod": pod["name"],
        "conntrackCount": count,
        "conntrackMax": max_value,
        "usagePercent": usage_percent,
        "status": node_status,
        "reasons": node_reasons,
        "rawLogPath": str(raw_path),
    })

if any(node["status"] == "fail" for node in nodes):
    status = "fail"
    reasons.append("one or more nodes have high conntrack usage")
elif any(node["status"] == "warn" for node in nodes):
    status = "warn"
    reasons.append("one or more nodes have conntrack warning signals")

if not nodes:
    status = "skipped"
    reasons.append("no ready conntrack snapshot pods found")

result = {
    "schemaVersion": "network-baseline.health.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
        "nodeCount": len(nodes),
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "conntrack-snapshot",
    },
    "checks": nodes,
    "status": status,
    "reasons": reasons,
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"${SCENARIO}: {status} nodes={len(nodes)}")
PY

echo "result: ${result_json}"
