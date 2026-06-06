#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-network-policy-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-networkpolicy-allow-deny}"
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

cleanup_policy() {
  kubectl -n "${NAMESPACE}" delete networkpolicy network-baseline-allow-policy-check --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" delete networkpolicy network-baseline-deny-iperf3-ingress --ignore-not-found >/dev/null 2>&1 || true
}

need_cmd kubectl
need_cmd python3

mkdir -p "${ARTIFACT_DIR}"

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
kubectl -n "${NAMESPACE}" apply -f "${ROOT_DIR}/deploy/iperf3/server.yaml"
kubectl -n "${NAMESPACE}" rollout status deploy/iperf3-server --timeout=120s

trap cleanup_policy EXIT
cleanup_policy

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
result_json="${ARTIFACT_DIR}/${SCENARIO}.result.json"
deny_policy_yaml="${ARTIFACT_DIR}/networkpolicy-deny-iperf3-ingress.yaml"
allow_policy_yaml="${ARTIFACT_DIR}/networkpolicy-allow-policy-check.yaml"

cp "${ROOT_DIR}/deploy/checks/networkpolicy-deny-iperf3-ingress.yaml" "${deny_policy_yaml}"
cp "${ROOT_DIR}/deploy/checks/networkpolicy-allow-policy-check.yaml" "${allow_policy_yaml}"

kubectl -n "${NAMESPACE}" apply -f "${deny_policy_yaml}"
kubectl -n "${NAMESPACE}" apply -f "${allow_policy_yaml}"

run_policy_check() {
  local name="$1"
  local component="$2"
  local expect_connect="$3"
  local job_name="network-policy-${name}-${RUN_ID,,}"
  job_name="${job_name//_/-}"
  job_name="${job_name:0:63}"
  local job_yaml="${ARTIFACT_DIR}/${SCENARIO}.${name}.job.yaml"
  local raw_log="${ARTIFACT_DIR}/${SCENARIO}.${name}.log"

  python3 - <<PY
from pathlib import Path

src = Path("${ROOT_DIR}/deploy/checks/networkpolicy-connect-job.yaml").read_text(encoding="utf-8")
src = src.replace("name: network-health-networkpolicy-connect", "name: ${job_name}", 1)
src = src.replace("app.kubernetes.io/component: networkpolicy-check", "app.kubernetes.io/component: ${component}")
src = src.replace("value: iperf3-server", "value: ${SERVICE_NAME}", 1)
src = src.replace('value: "5201"', 'value: "${SERVICE_PORT}"', 1)
src = src.replace('value: "5"', 'value: "${CONNECT_TIMEOUT_SECONDS}"', 1)
src = src.replace('value: "true"', 'value: "${expect_connect}"', 1)
Path("${job_yaml}").write_text(src, encoding="utf-8")
PY

  kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found
  kubectl -n "${NAMESPACE}" apply -f "${job_yaml}"

  local status="pass"
  if ! kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout="$((CONNECT_TIMEOUT_SECONDS + 120))s"; then
    status="fail"
  fi
  kubectl -n "${NAMESPACE}" logs "job/${job_name}" >"${raw_log}" 2>&1 || true

  local check_pod
  local check_node
  check_pod="$(kubectl -n "${NAMESPACE}" get pod -l job-name="${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  check_node=""
  if [[ -n "${check_pod}" ]]; then
    check_node="$(kubectl -n "${NAMESPACE}" get pod "${check_pod}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  fi

  python3 - <<PY
import json
from pathlib import Path

raw_log = Path("${raw_log}").read_text(encoding="utf-8", errors="replace")
result = {
    "name": "${name}",
    "status": "${status}",
    "expectConnect": "${expect_connect}" == "true",
    "component": "${component}",
    "jobName": "${job_name}",
    "pod": "${check_pod}",
    "node": "${check_node}",
    "rawLogPath": "${raw_log}",
    "rawLog": raw_log,
}
Path("${ARTIFACT_DIR}/${SCENARIO}.${name}.check.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

run_policy_check "allow" "networkpolicy-allow-check" "true"

kubectl -n "${NAMESPACE}" delete networkpolicy network-baseline-allow-policy-check --ignore-not-found
run_policy_check "deny" "networkpolicy-deny-check" "false"

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - <<PY
import json
from pathlib import Path

root = Path("${ARTIFACT_DIR}")
checks = [
    json.loads(path.read_text(encoding="utf-8"))
    for path in sorted(root.glob("${SCENARIO}.*.check.json"))
]
status = "pass"
reasons = []
if any(check["status"] == "fail" for check in checks):
    status = "fail"
    for check in checks:
        if check["status"] == "fail":
            if check["name"] == "allow":
                reasons.append("NetworkPolicy allow path could not connect")
            elif check["name"] == "deny":
                reasons.append("NetworkPolicy deny path was not blocked")
            else:
                reasons.append(f"NetworkPolicy check failed: {check['name']}")

result = {
    "schemaVersion": "network-baseline.health.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "networkpolicy-allow-deny",
        "serviceName": "${SERVICE_NAME}",
        "servicePort": int("${SERVICE_PORT}"),
    },
    "checks": checks,
    "status": status,
    "reasons": reasons,
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"${SCENARIO}: {status} checks={len(checks)}")
PY

echo "result: ${result_json}"
