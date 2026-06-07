#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-mtu-smoke-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-mtu-smoke}"
PING_PAYLOAD_SIZES="${PING_PAYLOAD_SIZES:-1200 1400}"
HIGH_MTU_PING_PAYLOAD_SIZES="${HIGH_MTU_PING_PAYLOAD_SIZES:-1472}"
PING_COUNT="${PING_COUNT:-3}"
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-5}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"

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
kubectl -n "${NAMESPACE}" apply -f "${ROOT_DIR}/deploy/iperf3/server.yaml"
kubectl -n "${NAMESPACE}" rollout status deploy/iperf3-server --timeout=120s

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
server_pod="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=network-baseline,app.kubernetes.io/component=iperf3-server -o jsonpath='{.items[0].metadata.name}')"
server_pod_ip="$(kubectl -n "${NAMESPACE}" get pod "${server_pod}" -o jsonpath='{.status.podIP}')"
server_node="$(kubectl -n "${NAMESPACE}" get pod "${server_pod}" -o jsonpath='{.spec.nodeName}')"
job_name="network-health-${SCENARIO}-${RUN_ID,,}"
job_name="${job_name//_/-}"
job_name="${job_name:0:63}"
job_yaml="${ARTIFACT_DIR}/${SCENARIO}.job.yaml"
raw_log="${ARTIFACT_DIR}/${SCENARIO}.log"
result_json="${ARTIFACT_DIR}/${SCENARIO}.result.json"

python3 - <<PY
from pathlib import Path

src = Path("${ROOT_DIR}/deploy/checks/mtu-ping-job.yaml").read_text(encoding="utf-8")
src = src.replace("name: network-health-mtu-ping", "name: ${job_name}", 1)
src = src.replace('value: "127.0.0.1"', 'value: "${server_pod_ip}"', 1)
src = src.replace('value: "1200 1400"', 'value: "${PING_PAYLOAD_SIZES}"', 1)
src = src.replace('value: "1472"', 'value: "${HIGH_MTU_PING_PAYLOAD_SIZES}"', 1)
src = src.replace('value: "3"', 'value: "${PING_COUNT}"', 1)
src = src.replace('value: "5"', 'value: "${PING_TIMEOUT_SECONDS}"', 1)
Path("${job_yaml}").write_text(src, encoding="utf-8")
PY

kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found
kubectl -n "${NAMESPACE}" apply -f "${job_yaml}"

status="pass"
reason=""
if ! kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout="$((PING_TIMEOUT_SECONDS * PING_COUNT + 120))s"; then
  status="fail"
  reason="MTU smoke ping failed"
fi

kubectl -n "${NAMESPACE}" logs "job/${job_name}" >"${raw_log}" 2>&1 || true
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
check_pod="$(kubectl -n "${NAMESPACE}" get pod -l job-name="${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
check_node=""
if [[ -n "${check_pod}" ]]; then
  check_node="$(kubectl -n "${NAMESPACE}" get pod "${check_pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
fi

python3 - <<PY
import json
from pathlib import Path

raw_log = Path("${raw_log}").read_text(encoding="utf-8", errors="replace")
payload_sizes = [int(size) for size in "${PING_PAYLOAD_SIZES}".split()]
high_mtu_payload_sizes = [int(size) for size in "${HIGH_MTU_PING_PAYLOAD_SIZES}".split()]
reasons = []
if "${reason}":
    reasons.append("${reason}")
result = {
    "schemaVersion": "network-baseline.health.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
        "serverPod": "${server_pod}",
        "serverNode": "${server_node}",
        "checkPod": "${check_pod}",
        "checkNode": "${check_node}",
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "mtu-smoke",
        "targetPodIp": "${server_pod_ip}",
        "payloadSizes": payload_sizes,
        "requiredPayloadSizes": payload_sizes,
        "highMtuProbePayloadSizes": high_mtu_payload_sizes,
        "pingCount": int("${PING_COUNT}"),
        "pingTimeoutSeconds": int("${PING_TIMEOUT_SECONDS}"),
    },
    "status": "${status}",
    "reasons": reasons,
    "rawLogPath": "${raw_log}",
    "rawLog": raw_log,
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print("${SCENARIO}: ${status} target=${server_pod_ip} sizes=" + str(payload_sizes) + " highMtuProbeSizes=" + str(high_mtu_payload_sizes))
PY

echo "result: ${result_json}"
