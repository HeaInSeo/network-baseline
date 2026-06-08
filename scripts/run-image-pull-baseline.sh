#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-image-pull-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-image-pull-baseline}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"
PRIMARY_REGISTRY_NAME="${PRIMARY_REGISTRY_NAME:-harbor}"
MIRROR_REGISTRY_NAME="${MIRROR_REGISTRY_NAME:-ghcr}"
PRIMARY_IMAGE="${PRIMARY_IMAGE:-${HARBOR_IMAGE:-}}"
MIRROR_IMAGE="${MIRROR_IMAGE:-${GHCR_IMAGE:-}}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-}"
IMAGE_PULL_TIMEOUT_SECONDS="${IMAGE_PULL_TIMEOUT_SECONDS:-180}"
KEEP_IMAGE_PULL_PODS="${KEEP_IMAGE_PULL_PODS:-0}"

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

render_probe() {
  local role="$1"
  local image="$2"
  local pod_name="$3"
  local pod_yaml="$4"

  python3 - <<PY
from pathlib import Path

src = Path("${ROOT_DIR}/deploy/genomic/image-pull-probe-pod.yaml").read_text(encoding="utf-8")
src = src.replace("name: image-pull-probe", "name: ${pod_name}", 1)
src = src.replace("image: busybox:1.36", "image: ${image}", 1)
src = src.replace("imagePullPolicy: Always", "imagePullPolicy: Always", 1)
src = src.replace("app.kubernetes.io/component: image-pull-probe", "app.kubernetes.io/component: image-pull-${role}", 1)
insert = ""
if "${SERVICE_ACCOUNT_NAME}":
    insert += "  serviceAccountName: ${SERVICE_ACCOUNT_NAME}\\n"
if "${IMAGE_PULL_SECRET}":
    insert += "  imagePullSecrets:\\n    - name: ${IMAGE_PULL_SECRET}\\n"
if insert:
    src = src.replace("  restartPolicy: Never\\n", insert + "  restartPolicy: Never\\n", 1)
Path("${pod_yaml}").write_text(src, encoding="utf-8")
PY
}

run_probe() {
  local role="$1"
  local registry_name="$2"
  local image="$3"
  local pod_name pod_yaml pod_json pod_events pod_describe status_file start_epoch now_epoch elapsed=0

  pod_name="image-pull-${role}-${RUN_ID,,}"
  pod_name="${pod_name//_/-}"
  pod_name="${pod_name:0:63}"
  pod_yaml="${ARTIFACT_DIR}/${SCENARIO}.${role}.pod.yaml"
  pod_json="${ARTIFACT_DIR}/${SCENARIO}.${role}.pod.json"
  pod_events="${ARTIFACT_DIR}/${SCENARIO}.${role}.events.json"
  pod_describe="${ARTIFACT_DIR}/${SCENARIO}.${role}.describe.txt"
  status_file="${ARTIFACT_DIR}/${SCENARIO}.${role}.status.json"

  if [[ -z "${image}" ]]; then
    python3 - <<PY
import json
from pathlib import Path
Path("${status_file}").write_text(json.dumps({
  "role": "${role}",
  "registry": "${registry_name}",
  "status": "skipped",
  "reason": "image not configured",
}, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
PY
    return 0
  fi

  render_probe "${role}" "${image}" "${pod_name}" "${pod_yaml}"
  kubectl -n "${NAMESPACE}" delete pod "${pod_name}" --ignore-not-found --wait=true >/dev/null

  start_epoch="$(date +%s)"
  kubectl -n "${NAMESPACE}" apply -f "${pod_yaml}" >/dev/null

  while true; do
    kubectl -n "${NAMESPACE}" get pod "${pod_name}" -o json >"${pod_json}" 2>/dev/null || true
    now_epoch="$(date +%s)"
    elapsed=$((now_epoch - start_epoch))

    if python3 - "${pod_json}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists() or not path.read_text(encoding="utf-8", errors="replace").strip():
    sys.exit(1)
pod = json.loads(path.read_text(encoding="utf-8"))
statuses = pod.get("status", {}).get("containerStatuses", [])
if not statuses:
    sys.exit(1)
state = statuses[0].get("state", {})
waiting = state.get("waiting") or {}
reason = waiting.get("reason", "")
image_id = statuses[0].get("imageID", "")
if image_id:
    sys.exit(0)
if reason in {"ErrImagePull", "ImagePullBackOff", "InvalidImageName"}:
    sys.exit(0)
sys.exit(1)
PY
    then
      break
    fi

    if [[ "${elapsed}" -ge "${IMAGE_PULL_TIMEOUT_SECONDS}" ]]; then
      break
    fi
    sleep 2
  done

  kubectl -n "${NAMESPACE}" get events --field-selector involvedObject.name="${pod_name}" -o json >"${pod_events}" 2>/dev/null || true
  kubectl -n "${NAMESPACE}" describe pod "${pod_name}" >"${pod_describe}" 2>&1 || true

  python3 - <<PY
import json
import re
from pathlib import Path

pod_path = Path("${pod_json}")
events_path = Path("${pod_events}")
status = "fail"
reason = "pod status unavailable"
phase = ""
image_id = ""
digest = ""
waiting_reason = ""
terminated_reason = ""
pod = {}
if pod_path.exists() and pod_path.read_text(encoding="utf-8", errors="replace").strip():
    pod = json.loads(pod_path.read_text(encoding="utf-8"))
    phase = pod.get("status", {}).get("phase", "")
    statuses = pod.get("status", {}).get("containerStatuses", [])
    if statuses:
        container_status = statuses[0]
        image_id = container_status.get("imageID", "")
        state = container_status.get("state", {})
        waiting = state.get("waiting") or {}
        terminated = state.get("terminated") or {}
        waiting_reason = waiting.get("reason", "")
        terminated_reason = terminated.get("reason", "")
        if image_id:
            status = "pass"
            reason = "image pulled"
        elif waiting_reason in {"ErrImagePull", "ImagePullBackOff", "InvalidImageName"}:
            status = "fail"
            reason = waiting_reason
        else:
            status = "fail"
            reason = waiting_reason or terminated_reason or phase or "image pull did not complete"

match = re.search(r"sha256:[0-9a-fA-F]{64}", image_id)
if match:
    digest = match.group(0).lower()

event_count = 0
if events_path.exists() and events_path.read_text(encoding="utf-8", errors="replace").strip():
    try:
        event_count = len(json.loads(events_path.read_text(encoding="utf-8")).get("items", []))
    except json.JSONDecodeError:
        event_count = 0

summary = {
    "role": "${role}",
    "registry": "${registry_name}",
    "image": "${image}",
    "pod": "${pod_name}",
    "status": status,
    "reason": reason,
    "phase": phase,
    "imageID": image_id,
    "digest": digest,
    "waitingReason": waiting_reason,
    "terminatedReason": terminated_reason,
    "elapsedSeconds": int("${elapsed}"),
    "eventCount": event_count,
    "artifacts": {
        "podYaml": "${pod_yaml}",
        "podJson": "${pod_json}",
        "eventsJson": "${pod_events}",
        "describe": "${pod_describe}",
    },
}
Path("${status_file}").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
print(f"${SCENARIO}-${role}: {status} image=${image} elapsed={int('${elapsed}')}s reason={reason}")
PY

  if [[ "${KEEP_IMAGE_PULL_PODS}" != "1" ]]; then
    kubectl -n "${NAMESPACE}" delete pod "${pod_name}" --ignore-not-found --wait=true >/dev/null
  fi
}

run_probe "primary" "${PRIMARY_REGISTRY_NAME}" "${PRIMARY_IMAGE}"
run_probe "mirror" "${MIRROR_REGISTRY_NAME}" "${MIRROR_IMAGE}"

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
    reasons.append("primary image not configured")
elif primary["status"] == "fail":
    status = "fail"
    reasons.append("primary registry image pull failed")

if mirror["status"] == "fail":
    if status == "pass":
        status = "warn"
    reasons.append("mirror registry image pull failed")
elif mirror["status"] == "skipped":
    if status == "pass":
        status = "warn"
    reasons.append("mirror image not configured")

primary_digest = primary.get("digest", "")
mirror_digest = mirror.get("digest", "")
digest_matched = False
if primary_digest and mirror_digest:
    digest_matched = primary_digest == mirror_digest
    if not digest_matched:
        if status == "pass":
            status = "warn"
        reasons.append("primary and mirror digests differ")

result = {
    "schemaVersion": "network-baseline.genomic.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "image-pull-baseline",
    },
    "imagePull": {
        "primaryRegistry": "${PRIMARY_REGISTRY_NAME}",
        "mirrorRegistry": "${MIRROR_REGISTRY_NAME}",
        "primary": primary,
        "mirror": mirror,
        "primaryDigest": primary_digest,
        "mirrorDigest": mirror_digest,
        "digestMatched": digest_matched,
    },
    "status": status,
    "reasons": reasons,
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
print(f"${SCENARIO}: {status} primary={primary.get('status')} mirror={mirror.get('status')} digestMatched={digest_matched}")
PY

echo "result: ${result_json}"
