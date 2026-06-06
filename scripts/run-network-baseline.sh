#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-network-baseline-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-service-tcp}"
PROTOCOL="${PROTOCOL:-}"
IPERF_DURATION="${IPERF_DURATION:-10}"
IPERF_PARALLEL="${IPERF_PARALLEL:-1}"
IPERF_BANDWIDTH="${IPERF_BANDWIDTH:-100M}"
PROFILE="${PROFILE:-operational}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"
SERVER_HOST="iperf3-server"
SCENARIO_PATH="pod-service-pod"
PLACEMENT="any"

if [[ -z "${PROTOCOL}" ]]; then
  case "${SCENARIO}" in
    *-udp)
      PROTOCOL="udp"
      ;;
    *)
      PROTOCOL="tcp"
      ;;
  esac
fi

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
job_name="iperf3-client-${SCENARIO}-${RUN_ID,,}"
job_name="${job_name//_/-}"
job_name="${job_name:0:63}"
job_yaml="${ARTIFACT_DIR}/${SCENARIO}.client-job.yaml"
iperf_json="${ARTIFACT_DIR}/${SCENARIO}.iperf3.json"
result_json="${ARTIFACT_DIR}/${SCENARIO}.result.json"

server_pod="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=network-baseline,app.kubernetes.io/component=iperf3-server -o jsonpath='{.items[0].metadata.name}')"
server_pod_ip="$(kubectl -n "${NAMESPACE}" get pod "${server_pod}" -o jsonpath='{.status.podIP}')"
server_node="$(kubectl -n "${NAMESPACE}" get pod "${server_pod}" -o jsonpath='{.spec.nodeName}')"
node_count="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | wc -l | tr -d ' ')"

write_skipped_result() {
  local reason="$1"
  local finished_at
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - <<PY
import json
from pathlib import Path

result = {
    "schemaVersion": "network-baseline.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
        "serverPod": "${server_pod}",
        "serverNode": "${server_node}",
    },
    "scenario": {
        "name": "${SCENARIO}",
        "protocol": "${PROTOCOL}",
        "path": "${SCENARIO_PATH}",
        "placement": "${PLACEMENT}",
    },
    "metrics": {
        "bitsPerSecond": 0,
        "bytesPerSecond": 0,
        "retransmits": 0,
        "jitterMs": 0,
        "lostPercent": 0,
    },
    "status": "skipped",
    "reasons": ["${reason}"],
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  echo "result: ${result_json}"
}

case "${SCENARIO}" in
  service-tcp | service-udp)
    SERVER_HOST="iperf3-server"
    SCENARIO_PATH="pod-service-pod"
    PLACEMENT="any"
    ;;
  pod-direct-tcp | pod-direct-udp)
    SERVER_HOST="${server_pod_ip}"
    SCENARIO_PATH="pod-ip-pod"
    PLACEMENT="any"
    ;;
  same-node-service-tcp)
    SERVER_HOST="iperf3-server"
    SCENARIO_PATH="pod-service-pod"
    PLACEMENT="same-node"
    ;;
  cross-node-service-tcp)
    SERVER_HOST="iperf3-server"
    SCENARIO_PATH="pod-service-pod"
    PLACEMENT="cross-node"
    if [[ "${node_count}" -lt 2 ]]; then
      write_skipped_result "cross-node scenario requires at least two schedulable nodes"
      exit 0
    fi
    ;;
esac

extra_args="-t ${IPERF_DURATION} -P ${IPERF_PARALLEL}"
if [[ "${PROTOCOL}" == "udp" ]]; then
  extra_args="-u -b ${IPERF_BANDWIDTH} -t ${IPERF_DURATION}"
fi

python3 - <<PY
from pathlib import Path
src = Path("${ROOT_DIR}/deploy/iperf3/client-job.yaml").read_text()
src = src.replace("name: iperf3-client", "name: ${job_name}", 1)
src = src.replace("value: iperf3-server", "value: ${SERVER_HOST}", 1)
src = src.replace('value: "-t 10"', 'value: "${extra_args}"')
affinity = ""
if "${PLACEMENT}" == "same-node":
    affinity = """      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app.kubernetes.io/name: network-baseline
                  app.kubernetes.io/component: iperf3-server
              topologyKey: kubernetes.io/hostname
"""
elif "${PLACEMENT}" == "cross-node":
    affinity = """      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app.kubernetes.io/name: network-baseline
                  app.kubernetes.io/component: iperf3-server
              topologyKey: kubernetes.io/hostname
"""
if affinity:
    src = src.replace("      containers:\n", affinity + "      containers:\n", 1)
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
client_pod="$(kubectl -n "${NAMESPACE}" get pod -l job-name="${job_name}" -o jsonpath='{.items[0].metadata.name}')"
client_node="$(kubectl -n "${NAMESPACE}" get pod "${client_pod}" -o jsonpath='{.spec.nodeName}')"

python3 "${ROOT_DIR}/tools/summary/summarize-network-baseline.py" \
  --iperf-json "${iperf_json}" \
  --out "${result_json}" \
  --run-id "${RUN_ID}" \
  --scenario "${SCENARIO}" \
  --protocol "${PROTOCOL}" \
  --path "${SCENARIO_PATH}" \
  --placement "${PLACEMENT}" \
  --namespace "${NAMESPACE}" \
  --server-pod "${server_pod}" \
  --server-node "${server_node}" \
  --client-pod "${client_pod}" \
  --client-node "${client_node}" \
  --started-at "${started_at}" \
  --finished-at "${finished_at}" \
  --profile "${PROFILE}"

echo "result: ${result_json}"
