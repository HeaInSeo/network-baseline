#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-genomic-environment-$(date -u +%Y%m%dT%H%M%SZ)}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"

mkdir -p "${ARTIFACT_DIR}"

env RUN_ID="${RUN_ID}" NAMESPACE="${NAMESPACE}" SCENARIO="image-pull-baseline" ARTIFACT_DIR="${ARTIFACT_DIR}" \
  "${ROOT_DIR}/scripts/run-image-pull-baseline.sh"

env RUN_ID="${RUN_ID}" NAMESPACE="${NAMESPACE}" SCENARIO="registry-connectivity-baseline" ARTIFACT_DIR="${ARTIFACT_DIR}" \
  "${ROOT_DIR}/scripts/run-registry-connectivity-baseline.sh"

env RUN_ID="${RUN_ID}" NAMESPACE="${NAMESPACE}" SCENARIO="remote-fetch-http-baseline" ARTIFACT_DIR="${ARTIFACT_DIR}" \
  "${ROOT_DIR}/scripts/run-remote-fetch-http-baseline.sh"

env RUN_ID="${RUN_ID}" NAMESPACE="${NAMESPACE}" SCENARIO="local-reuse-same-node-baseline" ARTIFACT_DIR="${ARTIFACT_DIR}" \
  "${ROOT_DIR}/scripts/run-local-reuse-same-node-baseline.sh"

env RUN_ID="${RUN_ID}" NAMESPACE="${NAMESPACE}" SCENARIO="job-churn-gc-baseline" ARTIFACT_DIR="${ARTIFACT_DIR}" \
  "${ROOT_DIR}/scripts/run-job-churn-gc-baseline.sh"

env RUN_ID="${RUN_ID}" NAMESPACE="${NAMESPACE}" ARTIFACT_DIR="${ARTIFACT_DIR}" \
  "${ROOT_DIR}/scripts/run-k8sgpt-analysis.sh"

python3 - <<PY
import json
from pathlib import Path

root = Path("${ARTIFACT_DIR}")
results = []
for path in sorted(root.glob("*.result.json")):
    results.append(json.loads(path.read_text(encoding="utf-8")))
k8sgpt_path = root / "k8sgpt-analysis.summary.json"
if k8sgpt_path.exists():
    results.append(json.loads(k8sgpt_path.read_text(encoding="utf-8")))

status = "pass"
if any(r.get("status") == "fail" for r in results):
    status = "fail"
elif any(r.get("status") == "warn" for r in results):
    status = "warn"
elif all(r.get("status") == "skipped" for r in results if "status" in r):
    status = "skipped"
elif any(r.get("status") == "skipped" for r in results):
    status = "warn"

summary = {
    "schemaVersion": "network-baseline.genomicMatrix.v1",
    "runId": "${RUN_ID}",
    "status": status,
    "results": results,
}
(root / "genomic-environment-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
print(f"genomic-environment-baseline: {status} results={len(results)} path={root / 'genomic-environment-summary.json'}")
PY

python3 "${ROOT_DIR}/tools/report/render-network-baseline-report.py" \
  --run-dir "${ARTIFACT_DIR}" \
  --summary "${ARTIFACT_DIR}/genomic-environment-summary.json" \
  --out "${ARTIFACT_DIR}/report.md"
