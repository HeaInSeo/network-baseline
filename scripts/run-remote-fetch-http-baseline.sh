#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-remote-fetch-http-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-remote-fetch-http-baseline}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"
FETCH_URL="${FETCH_URL:-${REMOTE_FETCH_URL:-}}"
EXPECTED_SHA256="${EXPECTED_SHA256:-${REMOTE_FETCH_SHA256:-}}"
CONNECT_TIMEOUT_SECONDS="${CONNECT_TIMEOUT_SECONDS:-5}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-120}"

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
job_name="remote-fetch-${RUN_ID,,}"
job_name="${job_name//_/-}"
job_name="${job_name:0:63}"
job_yaml="${ARTIFACT_DIR}/${SCENARIO}.job.yaml"
raw_log="${ARTIFACT_DIR}/${SCENARIO}.log"
describe_txt="${ARTIFACT_DIR}/${SCENARIO}.describe.txt"

if [[ -z "${FETCH_URL}" ]]; then
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - <<PY
import json
from pathlib import Path
result = {
    "schemaVersion": "network-baseline.genomic.remoteFetch.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {"namespace": "${NAMESPACE}"},
    "scenario": {
        "name": "${SCENARIO}",
        "type": "remote-fetch-http-baseline",
    },
    "remoteFetch": {
        "status": "skipped",
        "sourceUri": "",
        "reason": "FETCH_URL not configured",
    },
    "status": "skipped",
    "reasons": ["FETCH_URL not configured"],
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
print("${SCENARIO}: skipped sourceUrl not configured")
PY
  echo "result: ${result_json}"
  exit 0
fi

python3 - <<PY
from pathlib import Path

src = Path("${ROOT_DIR}/deploy/genomic/remote-fetch-http-job.yaml").read_text(encoding="utf-8")
src = src.replace("name: remote-fetch-http", "name: ${job_name}", 1)
src = src.replace("value: https://example.com/", "value: ${FETCH_URL}", 1)
src = src.replace('value: ""', 'value: "${EXPECTED_SHA256}"', 1)
src = src.replace('value: "5"', 'value: "${CONNECT_TIMEOUT_SECONDS}"', 1)
src = src.replace('value: "120"', 'value: "${REQUEST_TIMEOUT_SECONDS}"', 1)
Path("${job_yaml}").write_text(src, encoding="utf-8")
PY

kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found --wait=true >/dev/null
kubectl -n "${NAMESPACE}" apply -f "${job_yaml}" >/dev/null

status="pass"
reason=""
if ! kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout="$((REQUEST_TIMEOUT_SECONDS + 120))s" >/dev/null; then
  status="fail"
  reason="remote fetch job failed"
fi
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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

status = "${status}"
reason = "${reason}"
failure_layer = values.get("failureLayer", "")
curl_status = int(values.get("curlStatus", "1") or "1")
http_code = values.get("httpCode", "000")
if status == "fail" and not failure_layer:
    if curl_status != 0:
        failure_layer = "dns_or_tcp"
    elif http_code == "000":
        failure_layer = "http"
    else:
        failure_layer = "unknown"
if status == "fail" and not reason:
    reason = values.get("result", "remote fetch failed")

size_bytes = int(values.get("sizeBytes", "0") or "0")
fetch_seconds = int(values.get("fetchSeconds", "0") or "0")
digest = values.get("sha256", "")
digest_verified = values.get("digestVerified", "false") == "true"
cleanup_observed = values.get("cleanupObserved", "false") == "true"

result = {
    "schemaVersion": "network-baseline.genomic.remoteFetch.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
        "pod": "${pod_name}",
        "node": "${node_name}",
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "remote-fetch-http-baseline",
    },
    "remoteFetch": {
        "status": status,
        "sourceUri": "${FETCH_URL}",
        "sizeBytes": size_bytes,
        "fetchSeconds": fetch_seconds,
        "sha256": digest,
        "expectedSha256": "${EXPECTED_SHA256}",
        "digestVerified": digest_verified,
        "cleanupObserved": cleanup_observed,
        "failureLayer": failure_layer,
        "httpCode": http_code,
        "curlStatus": curl_status,
        "reason": reason,
        "artifacts": {
            "jobYaml": "${job_yaml}",
            "log": "${raw_log}",
            "describe": "${describe_txt}",
        },
    },
    "status": status,
    "reasons": [reason] if reason else [],
    "rawLog": raw,
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
print(f"${SCENARIO}: {status} source=${FETCH_URL} bytes={size_bytes} digestVerified={digest_verified}")
PY

kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found --wait=true >/dev/null

echo "result: ${result_json}"
