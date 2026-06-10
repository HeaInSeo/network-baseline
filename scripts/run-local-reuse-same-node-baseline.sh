#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-local-reuse-same-node-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-local-reuse-same-node-baseline}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"
NODE_LOCAL_HOST_PATH="${NODE_LOCAL_HOST_PATH:-/tmp/network-baseline-local-reuse}"
ARTIFACT_KIB="${ARTIFACT_KIB:-1024}"
JOB_TIMEOUT_SECONDS="${JOB_TIMEOUT_SECONDS:-180}"
KEEP_LOCAL_REUSE_JOBS="${KEEP_LOCAL_REUSE_JOBS:-0}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

need_cmd kubectl
need_cmd python3

mkdir -p "${ARTIFACT_DIR}"
kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
result_json="${ARTIFACT_DIR}/${SCENARIO}.result.json"
artifact_relative_dir="${RUN_ID}/${SCENARIO}"

render_job() {
  local role="$1"
  local job_name="$2"
  local job_yaml="$3"
  local node_name="$4"
  local expected_sha256="$5"
  local expected_size_bytes="$6"

  python3 - <<PY
from pathlib import Path

src = Path("${ROOT_DIR}/deploy/genomic/local-reuse-same-node-job.yaml").read_text(encoding="utf-8")
src = src.replace("name: local-reuse-same-node", "name: ${job_name}", 1)
src = src.replace("app.kubernetes.io/component: local-reuse-same-node", "app.kubernetes.io/component: local-reuse-${role}", 2)
src = src.replace("value: producer", "value: ${role}", 1)
src = src.replace("value: network-baseline-local-reuse/default", "value: ${artifact_relative_dir}", 1)
src = src.replace('value: "1024"', 'value: "${ARTIFACT_KIB}"', 1)
src = src.replace('value: ""', 'value: "${expected_sha256}"', 1)
src = src.replace('value: "0"', 'value: "${expected_size_bytes}"', 1)
src = src.replace("path: /tmp/network-baseline-local-reuse", "path: ${NODE_LOCAL_HOST_PATH}", 1)
if "${node_name}":
    src = src.replace("      restartPolicy: Never\\n", "      nodeName: ${node_name}\\n      restartPolicy: Never\\n", 1)
Path("${job_yaml}").write_text(src, encoding="utf-8")
PY
}

run_job() {
  local role="$1"
  local node_name="${2:-}"
  local expected_sha256="${3:-}"
  local expected_size_bytes="${4:-0}"
  local job_name job_yaml raw_log describe_txt pod_json status_file status reason pod_name actual_node

  job_name="local-reuse-${role}-${RUN_ID,,}"
  job_name="${job_name//_/-}"
  job_name="${job_name:0:63}"
  job_yaml="${ARTIFACT_DIR}/${SCENARIO}.${role}.job.yaml"
  raw_log="${ARTIFACT_DIR}/${SCENARIO}.${role}.log"
  describe_txt="${ARTIFACT_DIR}/${SCENARIO}.${role}.describe.txt"
  pod_json="${ARTIFACT_DIR}/${SCENARIO}.${role}.pod.json"
  status_file="${ARTIFACT_DIR}/${SCENARIO}.${role}.status.json"

  render_job "${role}" "${job_name}" "${job_yaml}" "${node_name}" "${expected_sha256}" "${expected_size_bytes}"
  kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found --wait=true >/dev/null
  kubectl -n "${NAMESPACE}" apply -f "${job_yaml}" >/dev/null

  status="pass"
  reason=""
  if ! kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout="${JOB_TIMEOUT_SECONDS}s" >/dev/null; then
    status="fail"
    reason="${role} job failed"
  fi

  kubectl -n "${NAMESPACE}" logs "job/${job_name}" >"${raw_log}" 2>&1 || true
  kubectl -n "${NAMESPACE}" describe job "${job_name}" >"${describe_txt}" 2>&1 || true
  pod_name="$(kubectl -n "${NAMESPACE}" get pod -l job-name="${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  actual_node=""
  if [[ -n "${pod_name}" ]]; then
    actual_node="$(kubectl -n "${NAMESPACE}" get pod "${pod_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    kubectl -n "${NAMESPACE}" get pod "${pod_name}" -o json >"${pod_json}" 2>/dev/null || true
  fi

  python3 - <<PY
import json
from pathlib import Path

raw = Path("${raw_log}").read_text(encoding="utf-8", errors="replace") if Path("${raw_log}").exists() else ""
values = {}
for line in raw.splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()

status = "${status}"
reason = "${reason}"
if status == "fail" and not reason:
    reason = values.get("failureLayer", "${role} failed")

summary = {
    "role": "${role}",
    "status": status,
    "reason": reason,
    "failureLayer": values.get("failureLayer", ""),
    "requestedNode": "${node_name}",
    "node": "${actual_node}",
    "pod": "${pod_name}",
    "artifactHostPath": "${NODE_LOCAL_HOST_PATH}",
    "artifactRelativeDir": "${artifact_relative_dir}",
    "artifactPath": values.get("artifactPath", ""),
    "sizeBytes": int(values.get("sizeBytes", "0") or "0"),
    "sha256": values.get("sha256", ""),
    "expectedSha256": values.get("expectedSha256", ""),
    "expectedSizeBytes": int(values.get("expectedSizeBytes", "0") or "0"),
    "digestVerified": values.get("digestVerified", "false") == "true",
    "sizeVerified": values.get("sizeVerified", "false") == "true",
    "cleanupObserved": values.get("cleanupObserved", "false") == "true",
    "artifacts": {
        "jobYaml": "${job_yaml}",
        "log": "${raw_log}",
        "describe": "${describe_txt}",
        "podJson": "${pod_json}",
    },
    "rawLog": raw,
}
Path("${status_file}").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
print(f"${SCENARIO}-${role}: {status} node=${actual_node} sha256={summary['sha256']}")
PY

  if [[ "${KEEP_LOCAL_REUSE_JOBS}" != "1" ]]; then
    kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found --wait=true >/dev/null
  fi
}

run_job "producer"

producer_status_file="${ARTIFACT_DIR}/${SCENARIO}.producer.status.json"
producer_node="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("node",""))' "${producer_status_file}")"
producer_sha256="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sha256",""))' "${producer_status_file}")"
producer_size_bytes="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sizeBytes",0))' "${producer_status_file}")"
producer_status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","fail"))' "${producer_status_file}")"

if [[ "${producer_status}" == "pass" && -n "${producer_node}" && -n "${producer_sha256}" && "${producer_size_bytes}" != "0" ]]; then
  run_job "consumer" "${producer_node}" "${producer_sha256}" "${producer_size_bytes}"
  run_job "cleanup" "${producer_node}" "${producer_sha256}" "${producer_size_bytes}"
else
  python3 - <<PY
import json
from pathlib import Path
for role, reason in (("consumer", "producer did not produce reusable artifact"), ("cleanup", "producer did not produce reusable artifact")):
    path = Path("${ARTIFACT_DIR}") / f"${SCENARIO}.{role}.status.json"
    path.write_text(json.dumps({
        "role": role,
        "status": "skipped",
        "reason": reason,
        "requestedNode": "${producer_node}",
    }, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
PY
fi

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - <<PY
import json
from pathlib import Path

artifact_dir = Path("${ARTIFACT_DIR}")
roles = {}
for role in ("producer", "consumer", "cleanup"):
    path = artifact_dir / f"${SCENARIO}.{role}.status.json"
    roles[role] = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {
        "role": role,
        "status": "fail",
        "reason": "status artifact missing",
    }

producer = roles["producer"]
consumer = roles["consumer"]
cleanup = roles["cleanup"]
same_node = bool(producer.get("node") and producer.get("node") == consumer.get("node"))
placement = "same-node" if same_node else "missed"
status = "pass"
reasons = []
for role, result in roles.items():
    if result.get("status") == "fail":
        status = "fail"
        reasons.append(f"{role} failed: {result.get('reason') or result.get('failureLayer') or 'unknown'}")
if status == "pass" and not same_node:
    status = "fail"
    reasons.append("consumer was not scheduled on producer node")
if status == "pass" and not consumer.get("digestVerified"):
    status = "fail"
    reasons.append("consumer digest verification failed")
if status == "pass" and not cleanup.get("cleanupObserved"):
    status = "warn"
    reasons.append("cleanup was not observed")
if consumer.get("status") == "skipped":
    status = "fail"
    reasons.append("consumer skipped")

result = {
    "schemaVersion": "network-baseline.genomic.localReuse.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "local-reuse-same-node-baseline",
    },
    "localReuse": {
        "status": status,
        "placement": placement,
        "nodeName": producer.get("node", ""),
        "producer": producer,
        "consumer": consumer,
        "cleanup": cleanup,
        "artifactHostPath": "${NODE_LOCAL_HOST_PATH}",
        "artifactRelativeDir": "${artifact_relative_dir}",
        "digestVerified": bool(consumer.get("digestVerified")),
        "sizeVerified": bool(consumer.get("sizeVerified")),
        "cleanupObserved": bool(cleanup.get("cleanupObserved")),
    },
    "status": status,
    "reasons": reasons,
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
print(f"${SCENARIO}: {status} placement={placement} node={producer.get('node','')} cleanup={cleanup.get('cleanupObserved')}")
PY

echo "result: ${result_json}"
