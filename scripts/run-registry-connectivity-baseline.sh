#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-registry-connectivity-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-registry-connectivity-baseline}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"
PRIMARY_REGISTRY_NAME="${PRIMARY_REGISTRY_NAME:-harbor}"
MIRROR_REGISTRY_NAME="${MIRROR_REGISTRY_NAME:-ghcr}"
PRIMARY_REGISTRY_URL="${PRIMARY_REGISTRY_URL:-${HARBOR_REGISTRY_URL:-}}"
MIRROR_REGISTRY_URL="${MIRROR_REGISTRY_URL:-${GHCR_REGISTRY_URL:-}}"
PRIMARY_IMAGE="${PRIMARY_IMAGE:-${HARBOR_IMAGE:-}}"
MIRROR_IMAGE="${MIRROR_IMAGE:-${GHCR_IMAGE:-}}"
CONNECT_TIMEOUT_SECONDS="${CONNECT_TIMEOUT_SECONDS:-5}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-20}"

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

derive_registry_url() {
  local image="$1"
  if [[ -z "${image}" ]]; then
    return 0
  fi
  python3 - "$image" <<'PY'
import sys
image = sys.argv[1]
first = image.split("/", 1)[0]
if "." in first or ":" in first or first == "localhost":
    print(f"https://{first}/v2/")
PY
}

if [[ -z "${PRIMARY_REGISTRY_URL}" ]]; then
  PRIMARY_REGISTRY_URL="$(derive_registry_url "${PRIMARY_IMAGE}")"
fi
if [[ -z "${MIRROR_REGISTRY_URL}" ]]; then
  MIRROR_REGISTRY_URL="$(derive_registry_url "${MIRROR_IMAGE}")"
fi

render_job() {
  local role="$1"
  local registry_name="$2"
  local registry_url="$3"
  local job_name="$4"
  local job_yaml="$5"

  python3 - <<PY
from pathlib import Path

src = Path("${ROOT_DIR}/deploy/genomic/registry-connectivity-job.yaml").read_text(encoding="utf-8")
src = src.replace("name: registry-connectivity", "name: ${job_name}", 1)
src = src.replace("app.kubernetes.io/component: registry-connectivity", "app.kubernetes.io/component: registry-connectivity-${role}", 2)
src = src.replace("value: primary", "value: ${role}", 1)
src = src.replace("value: harbor", "value: ${registry_name}", 1)
src = src.replace("value: https://harbor.example/v2/", "value: ${registry_url}", 1)
src = src.replace('value: "5"', 'value: "${CONNECT_TIMEOUT_SECONDS}"', 1)
src = src.replace('value: "20"', 'value: "${REQUEST_TIMEOUT_SECONDS}"', 1)
Path("${job_yaml}").write_text(src, encoding="utf-8")
PY
}

run_probe() {
  local role="$1"
  local registry_name="$2"
  local registry_url="$3"
  local job_name job_yaml raw_log describe_txt status_file status reason http_code curl_status body_bytes failure_layer started finished pod_name node_name

  job_name="registry-${role}-${RUN_ID,,}"
  job_name="${job_name//_/-}"
  job_name="${job_name:0:63}"
  job_yaml="${ARTIFACT_DIR}/${SCENARIO}.${role}.job.yaml"
  raw_log="${ARTIFACT_DIR}/${SCENARIO}.${role}.log"
  describe_txt="${ARTIFACT_DIR}/${SCENARIO}.${role}.describe.txt"
  status_file="${ARTIFACT_DIR}/${SCENARIO}.${role}.status.json"

  if [[ -z "${registry_url}" ]]; then
    python3 - <<PY
import json
from pathlib import Path
Path("${status_file}").write_text(json.dumps({
  "role": "${role}",
  "registry": "${registry_name}",
  "status": "skipped",
  "reason": "registry URL not configured",
}, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
PY
    return 0
  fi

  render_job "${role}" "${registry_name}" "${registry_url}" "${job_name}" "${job_yaml}"
  kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found --wait=true >/dev/null
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  kubectl -n "${NAMESPACE}" apply -f "${job_yaml}" >/dev/null

  status="pass"
  reason=""
  if ! kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout="$((REQUEST_TIMEOUT_SECONDS + 120))s" >/dev/null; then
    status="fail"
    reason="registry connectivity job failed"
  fi
  finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  kubectl -n "${NAMESPACE}" logs "job/${job_name}" >"${raw_log}" 2>&1 || true
  kubectl -n "${NAMESPACE}" describe job "${job_name}" >"${describe_txt}" 2>&1 || true
  pod_name="$(kubectl -n "${NAMESPACE}" get pod -l job-name="${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  node_name=""
  if [[ -n "${pod_name}" ]]; then
    node_name="$(kubectl -n "${NAMESPACE}" get pod "${pod_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
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

curl_status = int(values.get("curlStatus", "1") or "1")
http_code = values.get("httpCode", "000")
body_bytes = int(values.get("bodyBytes", "0") or "0")
job_status = "${status}"
reason = "${reason}"
failure_layer = ""
if job_status == "fail":
    if curl_status != 0:
        failure_layer = "tcp_tls_or_dns"
    elif http_code == "000":
        failure_layer = "http"
    else:
        failure_layer = "unknown"
if not reason and job_status == "fail":
    reason = values.get("result", "registry connectivity failed")

summary = {
    "role": "${role}",
    "registry": "${registry_name}",
    "url": "${registry_url}",
    "status": job_status,
    "reason": reason,
    "failureLayer": failure_layer,
    "httpCode": http_code,
    "curlStatus": curl_status,
    "bodyBytes": body_bytes,
    "pod": "${pod_name}",
    "node": "${node_name}",
    "startedAt": "${started}",
    "finishedAt": "${finished}",
    "artifacts": {
        "jobYaml": "${job_yaml}",
        "log": "${raw_log}",
        "describe": "${describe_txt}",
    },
    "rawLog": raw,
}
Path("${status_file}").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
print(f"${SCENARIO}-${role}: {job_status} registry=${registry_name} url=${registry_url} http={http_code}")
PY

  kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found --wait=true >/dev/null
}

run_probe "primary" "${PRIMARY_REGISTRY_NAME}" "${PRIMARY_REGISTRY_URL}"
run_probe "mirror" "${MIRROR_REGISTRY_NAME}" "${MIRROR_REGISTRY_URL}"

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - <<PY
import json
from pathlib import Path

artifact_dir = Path("${ARTIFACT_DIR}")
roles = {}
for role in ("primary", "mirror"):
    path = artifact_dir / f"${SCENARIO}.{role}.status.json"
    roles[role] = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {
        "role": role,
        "status": "fail",
        "reason": "status artifact missing",
    }

primary = roles["primary"]
mirror = roles["mirror"]
status = "pass"
reasons = []
if primary["status"] == "skipped":
    status = "skipped"
    reasons.append("primary registry URL not configured")
elif primary["status"] == "fail":
    status = "fail"
    reasons.append("primary registry connectivity failed")
if mirror["status"] == "fail":
    if status == "pass":
        status = "warn"
    reasons.append("mirror registry connectivity failed")
elif mirror["status"] == "skipped":
    if status == "pass":
        status = "warn"
    reasons.append("mirror registry URL not configured")

result = {
    "schemaVersion": "network-baseline.genomic.registry.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "registry-connectivity-baseline",
    },
    "registry": {
        "primaryRegistry": "${PRIMARY_REGISTRY_NAME}",
        "mirrorRegistry": "${MIRROR_REGISTRY_NAME}",
        "primary": primary,
        "mirror": mirror,
    },
    "status": status,
    "reasons": reasons,
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
print(f"${SCENARIO}: {status} primary={primary.get('status')} mirror={mirror.get('status')}")
PY

echo "result: ${result_json}"
