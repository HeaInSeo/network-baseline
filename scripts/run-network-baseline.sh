#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-network-baseline-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-service-tcp}"
PROTOCOL="${PROTOCOL:-tcp}"
IPERF_DURATION="${IPERF_DURATION:-10}"
IPERF_PARALLEL="${IPERF_PARALLEL:-1}"
IPERF_BANDWIDTH="${IPERF_BANDWIDTH:-100M}"
PROFILE="${PROFILE:-operational}"
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
job_name="iperf3-client-${RUN_ID,,}"
job_name="${job_name//_/-}"
job_name="${job_name:0:63}"
job_yaml="${ARTIFACT_DIR}/client-job.yaml"
iperf_json="${ARTIFACT_DIR}/${SCENARIO}.iperf3.json"
result_json="${ARTIFACT_DIR}/${SCENARIO}.result.json"

extra_args="-t ${IPERF_DURATION} -P ${IPERF_PARALLEL}"
if [[ "${PROTOCOL}" == "udp" ]]; then
  extra_args="-u -b ${IPERF_BANDWIDTH} -t ${IPERF_DURATION}"
fi

python3 - <<PY
from pathlib import Path
src = Path("${ROOT_DIR}/deploy/iperf3/client-job.yaml").read_text()
src = src.replace("name: iperf3-client", "name: ${job_name}", 1)
src = src.replace('value: "-t 10"', 'value: "${extra_args}"')
Path("${job_yaml}").write_text(src)
PY

kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found
kubectl -n "${NAMESPACE}" apply -f "${job_yaml}"
kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout="$((IPERF_DURATION + 120))s" || {
  kubectl -n "${NAMESPACE}" logs "job/${job_name}" >&2 || true
  exit 1
}
kubectl -n "${NAMESPACE}" logs "job/${job_name}" >"${iperf_json}"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 "${ROOT_DIR}/tools/summary/summarize-network-baseline.py" \
  --iperf-json "${iperf_json}" \
  --out "${result_json}" \
  --run-id "${RUN_ID}" \
  --scenario "${SCENARIO}" \
  --protocol "${PROTOCOL}" \
  --path "pod-service-pod" \
  --namespace "${NAMESPACE}" \
  --started-at "${started_at}" \
  --finished-at "${finished_at}" \
  --profile "${PROFILE}"

echo "result: ${result_json}"

