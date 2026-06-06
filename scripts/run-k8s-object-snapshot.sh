#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-k8s-object-snapshot-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-k8s-object-snapshot}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

snapshot() {
  local name="$1"
  shift
  if "$@" >"${ARTIFACT_DIR}/${SCENARIO}.${name}.json" 2>"${ARTIFACT_DIR}/${SCENARIO}.${name}.err"; then
    echo "pass" >"${ARTIFACT_DIR}/${SCENARIO}.${name}.status"
  else
    echo "fail" >"${ARTIFACT_DIR}/${SCENARIO}.${name}.status"
  fi
}

optional_snapshot() {
  local name="$1"
  shift
  if "$@" >"${ARTIFACT_DIR}/${SCENARIO}.${name}.json" 2>"${ARTIFACT_DIR}/${SCENARIO}.${name}.err"; then
    echo "pass" >"${ARTIFACT_DIR}/${SCENARIO}.${name}.status"
  else
    echo "skipped" >"${ARTIFACT_DIR}/${SCENARIO}.${name}.status"
  fi
}

need_cmd kubectl
need_cmd python3

mkdir -p "${ARTIFACT_DIR}"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
result_json="${ARTIFACT_DIR}/${SCENARIO}.result.json"

snapshot nodes kubectl get nodes -o json
snapshot pods_all kubectl get pods -A -o json
snapshot services_all kubectl get services -A -o json
snapshot endpoints_all kubectl get endpoints -A -o json
optional_snapshot endpointslices_all kubectl get endpointslices -A -o json
snapshot networkpolicies_all kubectl get networkpolicies -A -o json
snapshot events_all kubectl get events -A -o json
snapshot kube_system_pods kubectl get pods -n kube-system -o json

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - <<PY
import json
from pathlib import Path

artifact_dir = Path("${ARTIFACT_DIR}")
snapshot_names = [
    "nodes",
    "pods_all",
    "services_all",
    "endpoints_all",
    "endpointslices_all",
    "networkpolicies_all",
    "events_all",
    "kube_system_pods",
]

snapshots = {}
counts = {}
for name in snapshot_names:
    status_path = artifact_dir / f"${SCENARIO}.{name}.status"
    data_path = artifact_dir / f"${SCENARIO}.{name}.json"
    err_path = artifact_dir / f"${SCENARIO}.{name}.err"
    status = status_path.read_text(encoding="utf-8").strip() if status_path.exists() else "fail"
    count = None
    if status == "pass" and data_path.exists():
        try:
            parsed = json.loads(data_path.read_text(encoding="utf-8"))
            count = len(parsed.get("items", []))
        except json.JSONDecodeError:
            status = "fail"
    snapshots[name] = {
        "status": status,
        "path": str(data_path),
        "errorPath": str(err_path),
    }
    counts[name] = count

status = "pass"
reasons = []
failed = [name for name, snapshot in snapshots.items() if snapshot["status"] == "fail"]
if failed:
    status = "warn"
    reasons.append("one or more Kubernetes object snapshots could not be collected: " + ",".join(failed))

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
        "type": "k8s-object-snapshot",
    },
    "snapshots": snapshots,
    "counts": counts,
    "status": status,
    "reasons": reasons,
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"${SCENARIO}: {status} snapshots={len(snapshots)}")
PY

echo "result: ${result_json}"
