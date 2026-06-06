#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${RUN_ID:-network-baseline-matrix-$(date -u +%Y%m%dT%H%M%SZ)}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"

mkdir -p "${ARTIFACT_DIR}"

run_one() {
  local scenario="$1"
  local protocol="$2"
  env RUN_ID="${RUN_ID}" SCENARIO="${scenario}" PROTOCOL="${protocol}" ARTIFACT_DIR="${ARTIFACT_DIR}" \
    "${ROOT_DIR}/scripts/run-network-baseline.sh"
}

run_one service-tcp tcp
run_one service-udp udp
run_one pod-direct-tcp tcp
run_one pod-direct-udp udp
run_one same-node-service-tcp tcp
run_one cross-node-service-tcp tcp

python3 - <<PY
import json
from pathlib import Path

root = Path("${ARTIFACT_DIR}")
results = []
for path in sorted(root.glob("*.result.json")):
    results.append(json.loads(path.read_text(encoding="utf-8")))
status = "pass"
if any(r.get("status") == "fail" for r in results):
    status = "fail"
elif any(r.get("status") == "warn" for r in results):
    status = "warn"
summary = {
    "schemaVersion": "network-baseline.matrix.v1",
    "runId": "${RUN_ID}",
    "status": status,
    "results": results,
}
(root / "matrix-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"matrix: {status} results={len(results)} path={root / 'matrix-summary.json'}")
PY
