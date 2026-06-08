#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-k8sgpt-$(date -u +%Y%m%dT%H%M%SZ)}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"
K8SGPT_SCOPE="${K8SGPT_SCOPE:-namespace}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

need_cmd kubectl
need_cmd k8sgpt
need_cmd python3

mkdir -p "${ARTIFACT_DIR}"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
json_out="${ARTIFACT_DIR}/k8sgpt-analysis.json"
text_out="${ARTIFACT_DIR}/k8sgpt-analysis.txt"
stderr_out="${ARTIFACT_DIR}/k8sgpt-analysis.stderr"
summary_out="${ARTIFACT_DIR}/k8sgpt-analysis.summary.json"

if [[ "${K8SGPT_SCOPE}" == "namespace" ]]; then
  kubectl get namespace "${NAMESPACE}" >/dev/null
  analyze_args=(analyze --namespace "${NAMESPACE}")
else
  analyze_args=(analyze)
fi

set +e
k8sgpt "${analyze_args[@]}" --output=json >"${json_out}" 2>"${stderr_out}"
json_status=$?
k8sgpt "${analyze_args[@]}" >"${text_out}" 2>>"${stderr_out}"
text_status=$?
set -e

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - <<PY
import json
from pathlib import Path

json_path = Path("${json_out}")
stderr_path = Path("${stderr_out}")
raw = json_path.read_text(encoding="utf-8", errors="replace")
stderr = stderr_path.read_text(encoding="utf-8", errors="replace")
try:
    payload = json.loads(raw) if raw.strip() else []
except json.JSONDecodeError:
    payload = {"unparsed": raw}

if isinstance(payload, list):
    finding_count = len(payload)
elif isinstance(payload, dict):
    for key in ("results", "problems", "findings"):
        if isinstance(payload.get(key), list):
            finding_count = len(payload[key])
            break
    else:
        finding_count = 0 if not payload else 1
else:
    finding_count = 0

summary = {
    "schemaVersion": "network-baseline.k8sgpt.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "scope": "${K8SGPT_SCOPE}",
    "namespace": "${NAMESPACE}",
    "jsonExitCode": int("${json_status}"),
    "textExitCode": int("${text_status}"),
    "findingCount": finding_count,
    "status": "pass" if int("${json_status}") == 0 and int("${text_status}") == 0 else "fail",
    "artifacts": {
        "json": "${json_out}",
        "text": "${text_out}",
        "stderr": "${stderr_out}",
    },
    "stderr": stderr,
}
Path("${summary_out}").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"k8sgpt-analysis: {summary['status']} findings={finding_count} scope=${K8SGPT_SCOPE} namespace=${NAMESPACE}")
PY

if [[ "${json_status}" -ne 0 || "${text_status}" -ne 0 ]]; then
  echo "k8sgpt analyze failed; see ${stderr_out}" >&2
  exit 1
fi

echo "result: ${summary_out}"
