#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-network-health-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-dns-service-discovery}"
SERVICE_NAME="${SERVICE_NAME:-iperf3-server}"
SERVICE_PORT="${SERVICE_PORT:-5201}"
CONNECT_TIMEOUT_SECONDS="${CONNECT_TIMEOUT_SECONDS:-5}"
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
job_name="network-health-${SCENARIO}-${RUN_ID,,}"
job_name="${job_name//_/-}"
job_name="${job_name:0:63}"
job_yaml="${ARTIFACT_DIR}/${SCENARIO}.job.yaml"
raw_log="${ARTIFACT_DIR}/${SCENARIO}.log"
result_json="${ARTIFACT_DIR}/${SCENARIO}.result.json"
service_fqdn="${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"

python3 - <<PY
from pathlib import Path

src = Path("${ROOT_DIR}/deploy/checks/dns-service-job.yaml").read_text(encoding="utf-8")
src = src.replace("name: network-health-dns-service", "name: ${job_name}", 1)
src = src.replace("value: network-baseline", "value: ${NAMESPACE}", 1)
src = src.replace("value: iperf3-server", "value: ${SERVICE_NAME}", 1)
src = src.replace('value: "5201"', 'value: "${SERVICE_PORT}"', 1)
src = src.replace('value: "5"', 'value: "${CONNECT_TIMEOUT_SECONDS}"', 1)
Path("${job_yaml}").write_text(src, encoding="utf-8")
PY

kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found
kubectl -n "${NAMESPACE}" apply -f "${job_yaml}"

status="pass"
reason=""
if ! kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout="$((CONNECT_TIMEOUT_SECONDS + 120))s"; then
  status="fail"
  reason="dns or service discovery check failed"
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
        "checkPod": "${check_pod}",
        "checkNode": "${check_node}",
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "dns-service-discovery",
        "serviceName": "${SERVICE_NAME}",
        "serviceFqdn": "${service_fqdn}",
        "servicePort": int("${SERVICE_PORT}"),
    },
    "checks": {
        "shortNameResolution": {
            "target": "${SERVICE_NAME}",
            "required": False,
        },
        "fqdnResolution": "${service_fqdn}",
        "tcpConnectFqdn": "${service_fqdn}:${SERVICE_PORT}",
    },
    "status": "${status}",
    "reasons": reasons,
    "rawLogPath": "${raw_log}",
    "rawLog": raw_log,
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"${SCENARIO}: ${status} service=${service_fqdn}:${SERVICE_PORT}")
PY

echo "result: ${result_json}"
