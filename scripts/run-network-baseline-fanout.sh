#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-network-baseline-fanout-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-fanout-tcp-5}"
PROTOCOL="tcp"
IPERF_DURATION="${IPERF_DURATION:-10}"
IPERF_PARALLEL="${IPERF_PARALLEL:-1}"
FANOUT_CLIENTS="${FANOUT_CLIENTS:-}"
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

if [[ -z "${FANOUT_CLIENTS}" ]]; then
  case "${SCENARIO}" in
    fanout-tcp-5)
      FANOUT_CLIENTS=5
      ;;
    fanout-tcp-10)
      FANOUT_CLIENTS=10
      ;;
    fanout-tcp-20)
      FANOUT_CLIENTS=20
      ;;
    *)
      echo "unknown fanout scenario: ${SCENARIO}" >&2
      exit 1
      ;;
  esac
fi

mkdir -p "${ARTIFACT_DIR}"

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
kubectl -n "${NAMESPACE}" apply -f "${ROOT_DIR}/deploy/iperf3/server.yaml"
kubectl -n "${NAMESPACE}" rollout status deploy/iperf3-server --timeout=120s

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
server_pod="$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=network-baseline,app.kubernetes.io/component=iperf3-server -o jsonpath='{.items[0].metadata.name}')"
server_node="$(kubectl -n "${NAMESPACE}" get pod "${server_pod}" -o jsonpath='{.spec.nodeName}')"
extra_args="-t ${IPERF_DURATION} -P ${IPERF_PARALLEL}"

for index in $(seq 1 "${FANOUT_CLIENTS}"); do
  job_name="iperf3-client-${SCENARIO}-${index}-${RUN_ID,,}"
  job_name="${job_name//_/-}"
  job_name="${job_name:0:63}"
  job_yaml="${ARTIFACT_DIR}/${SCENARIO}.client-${index}.yaml"
  python3 - <<PY
from pathlib import Path

src = Path("${ROOT_DIR}/deploy/iperf3/client-job.yaml").read_text(encoding="utf-8")
src = src.replace("name: iperf3-client", "name: ${job_name}", 1)
src = src.replace('value: "-t 10"', 'value: "${extra_args}"')
Path("${job_yaml}").write_text(src, encoding="utf-8")
PY
  kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found
  kubectl -n "${NAMESPACE}" apply -f "${job_yaml}"
done

for index in $(seq 1 "${FANOUT_CLIENTS}"); do
  job_name="iperf3-client-${SCENARIO}-${index}-${RUN_ID,,}"
  job_name="${job_name//_/-}"
  job_name="${job_name:0:63}"
  kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout="$((IPERF_DURATION + 180))s" || {
    kubectl -n "${NAMESPACE}" logs "job/${job_name}" >&2 || true
    exit 1
  }
  kubectl -n "${NAMESPACE}" logs "job/${job_name}" >"${ARTIFACT_DIR}/${SCENARIO}.client-${index}.iperf3.json"
done

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

for index in $(seq 1 "${FANOUT_CLIENTS}"); do
  job_name="iperf3-client-${SCENARIO}-${index}-${RUN_ID,,}"
  job_name="${job_name//_/-}"
  job_name="${job_name:0:63}"
  client_pod="$(kubectl -n "${NAMESPACE}" get pod -l job-name="${job_name}" -o jsonpath='{.items[0].metadata.name}')"
  client_node="$(kubectl -n "${NAMESPACE}" get pod "${client_pod}" -o jsonpath='{.spec.nodeName}')"
  python3 "${ROOT_DIR}/tools/summary/summarize-network-baseline.py" \
    --iperf-json "${ARTIFACT_DIR}/${SCENARIO}.client-${index}.iperf3.json" \
    --out "${ARTIFACT_DIR}/${SCENARIO}.client-${index}.summary.json" \
    --run-id "${RUN_ID}" \
    --scenario "${SCENARIO}-client-${index}" \
    --protocol "${PROTOCOL}" \
    --path "pod-service-pod" \
    --placement "fanout" \
    --namespace "${NAMESPACE}" \
    --server-pod "${server_pod}" \
    --server-node "${server_node}" \
    --client-pod "${client_pod}" \
    --client-node "${client_node}" \
    --started-at "${started_at}" \
    --finished-at "${finished_at}" \
    --profile "${PROFILE}"
done

python3 - <<PY
import json
from pathlib import Path

root = Path("${ARTIFACT_DIR}")
client_results = [
    json.loads(path.read_text(encoding="utf-8"))
    for path in sorted(root.glob("${SCENARIO}.client-*.summary.json"))
]
bits = [result["metrics"]["bitsPerSecond"] for result in client_results]
status = "pass"
if any(result["status"] == "fail" for result in client_results):
    status = "fail"
elif any(result["status"] == "warn" for result in client_results):
    status = "warn"

metrics = {
    "bitsPerSecond": sum(bits),
    "bytesPerSecond": sum(bits) / 8,
    "clientCount": len(client_results),
    "minClientBitsPerSecond": min(bits) if bits else 0,
    "maxClientBitsPerSecond": max(bits) if bits else 0,
    "avgClientBitsPerSecond": (sum(bits) / len(bits)) if bits else 0,
}
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
        "path": "pod-service-pod",
        "placement": "fanout",
        "clientCount": len(client_results),
    },
    "metrics": metrics,
    "status": status,
    "reasons": [],
    "clientResults": client_results,
}
(root / "${SCENARIO}.result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"${SCENARIO}: {status} clients={len(client_results)} aggregateBitsPerSecond={metrics['bitsPerSecond']:.0f}")
PY

echo "result: ${ARTIFACT_DIR}/${SCENARIO}.result.json"
