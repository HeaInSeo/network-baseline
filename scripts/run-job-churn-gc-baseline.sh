#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-job-churn-gc-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-job-churn-gc-baseline}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts/network-baseline/${RUN_ID}}"
CHURN_JOBS="${CHURN_JOBS:-20}"
CHURN_SLEEP_SECONDS="${CHURN_SLEEP_SECONDS:-1}"
JOB_TIMEOUT_SECONDS="${JOB_TIMEOUT_SECONDS:-180}"
TTL_SECONDS_AFTER_FINISHED="${TTL_SECONDS_AFTER_FINISHED:-60}"
KEEP_CHURN_JOBS="${KEEP_CHURN_JOBS:-0}"
WARN_COMPLETION_SECONDS="${WARN_COMPLETION_SECONDS:-120}"

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
label_selector="app.kubernetes.io/name=network-baseline,network-baseline/run-id=${RUN_ID},network-baseline/scenario=${SCENARIO}"

snapshot_objects() {
  local phase="$1"
  kubectl -n "${NAMESPACE}" get jobs -l "${label_selector}" -o json >"${ARTIFACT_DIR}/${SCENARIO}.${phase}.jobs.json" 2>"${ARTIFACT_DIR}/${SCENARIO}.${phase}.jobs.err" || true
  kubectl -n "${NAMESPACE}" get pods -l "${label_selector}" -o json >"${ARTIFACT_DIR}/${SCENARIO}.${phase}.pods.json" 2>"${ARTIFACT_DIR}/${SCENARIO}.${phase}.pods.err" || true
  kubectl -n "${NAMESPACE}" get events -o json >"${ARTIFACT_DIR}/${SCENARIO}.${phase}.events.json" 2>"${ARTIFACT_DIR}/${SCENARIO}.${phase}.events.err" || true
}

render_job() {
  local index="$1"
  local job_name="$2"
  local job_yaml="$3"

  python3 - <<PY
from pathlib import Path

src = Path("${ROOT_DIR}/deploy/genomic/job-churn-gc-job.yaml").read_text(encoding="utf-8")
src = src.replace("name: job-churn-gc", "name: ${job_name}", 1)
src = src.replace("app.kubernetes.io/component: job-churn-gc", "app.kubernetes.io/component: job-churn-gc-${index}", 2)
src = src.replace('ttlSecondsAfterFinished: 300', 'ttlSecondsAfterFinished: ${TTL_SECONDS_AFTER_FINISHED}', 1)
src = src.replace('value: "1"', 'value: "${CHURN_SLEEP_SECONDS}"', 1)
extra_labels = """    network-baseline/run-id: ${RUN_ID}
    network-baseline/scenario: ${SCENARIO}
    network-baseline/churn-index: "${index}"
"""
src = src.replace("    app.kubernetes.io/component: job-churn-gc-${index}\\n", "    app.kubernetes.io/component: job-churn-gc-${index}\\n" + extra_labels, 1)
src = src.replace("        app.kubernetes.io/component: job-churn-gc-${index}\\n", "        app.kubernetes.io/component: job-churn-gc-${index}\\n" + extra_labels.replace("    ", "        "), 1)
Path("${job_yaml}").write_text(src, encoding="utf-8")
PY
}

snapshot_objects before

submit_start_epoch="$(date +%s)"
for index in $(seq 1 "${CHURN_JOBS}"); do
  job_name="churn-${index}-${RUN_ID,,}"
  job_name="${job_name//_/-}"
  job_name="${job_name:0:63}"
  job_yaml="${ARTIFACT_DIR}/${SCENARIO}.job-${index}.yaml"
  render_job "${index}" "${job_name}" "${job_yaml}"
  kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found --wait=true >/dev/null
  kubectl -n "${NAMESPACE}" apply -f "${job_yaml}" >/dev/null
done
submit_finished_epoch="$(date +%s)"

snapshot_objects submitted

wait_start_epoch="$(date +%s)"
completed=0
failed=0
wait_failures=()
for index in $(seq 1 "${CHURN_JOBS}"); do
  job_name="churn-${index}-${RUN_ID,,}"
  job_name="${job_name//_/-}"
  job_name="${job_name:0:63}"
  if kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout="${JOB_TIMEOUT_SECONDS}s" >/dev/null; then
    completed=$((completed + 1))
  else
    failed=$((failed + 1))
    wait_failures+=("${job_name}")
  fi
done
wait_finished_epoch="$(date +%s)"

snapshot_objects completed

for index in $(seq 1 "${CHURN_JOBS}"); do
  job_name="churn-${index}-${RUN_ID,,}"
  job_name="${job_name//_/-}"
  job_name="${job_name:0:63}"
  kubectl -n "${NAMESPACE}" logs "job/${job_name}" >"${ARTIFACT_DIR}/${SCENARIO}.job-${index}.log" 2>&1 || true
done

if [[ "${KEEP_CHURN_JOBS}" != "1" ]]; then
  kubectl -n "${NAMESPACE}" delete jobs -l "${label_selector}" --ignore-not-found --wait=true >/dev/null
fi

snapshot_objects after_cleanup
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - <<PY
import json
from pathlib import Path

root = Path("${ARTIFACT_DIR}")

def count_items(path):
    if not path.exists() or not path.read_text(encoding="utf-8", errors="replace").strip():
        return 0
    try:
        return len(json.loads(path.read_text(encoding="utf-8")).get("items", []))
    except json.JSONDecodeError:
        return 0

def phase_counts(phase):
    return {
        "jobs": count_items(root / f"${SCENARIO}.{phase}.jobs.json"),
        "pods": count_items(root / f"${SCENARIO}.{phase}.pods.json"),
        "events": count_items(root / f"${SCENARIO}.{phase}.events.json"),
    }

counts = {phase: phase_counts(phase) for phase in ("before", "submitted", "completed", "after_cleanup")}
submit_seconds = int("${submit_finished_epoch}") - int("${submit_start_epoch}")
completion_seconds = int("${wait_finished_epoch}") - int("${wait_start_epoch}")
created_jobs = int("${CHURN_JOBS}")
completed = int("${completed}")
failed = int("${failed}")
remaining_jobs = counts["after_cleanup"]["jobs"]
remaining_pods = counts["after_cleanup"]["pods"]
status = "pass"
reasons = []
if failed:
    status = "fail"
    reasons.append(f"{failed} churn jobs failed or timed out")
if remaining_jobs or remaining_pods:
    status = "warn" if status == "pass" else status
    reasons.append(f"cleanup left jobs={remaining_jobs} pods={remaining_pods}")
if completion_seconds > int("${WARN_COMPLETION_SECONDS}") and status == "pass":
    status = "warn"
    reasons.append(f"completion seconds {completion_seconds} exceeded warn threshold ${WARN_COMPLETION_SECONDS}")

result = {
    "schemaVersion": "network-baseline.genomic.churnGc.v1",
    "runId": "${RUN_ID}",
    "startedAt": "${started_at}",
    "finishedAt": "${finished_at}",
    "cluster": {
        "namespace": "${NAMESPACE}",
    },
    "scenario": {
        "name": "${SCENARIO}",
        "type": "job-churn-gc-baseline",
        "jobCount": created_jobs,
        "sleepSeconds": int("${CHURN_SLEEP_SECONDS}"),
        "ttlSecondsAfterFinished": int("${TTL_SECONDS_AFTER_FINISHED}"),
    },
    "churn": {
        "status": status,
        "jobsCreated": created_jobs,
        "jobsCompleted": completed,
        "jobsFailed": failed,
        "submitSeconds": submit_seconds,
        "completionSeconds": completion_seconds,
        "waitFailures": [item for item in "${wait_failures[*]}".split() if item],
    },
    "gc": {
        "status": "pass" if remaining_jobs == 0 and remaining_pods == 0 else "warn",
        "jobsRemaining": remaining_jobs,
        "podsRemaining": remaining_pods,
        "ttlSecondsAfterFinished": int("${TTL_SECONDS_AFTER_FINISHED}"),
        "explicitCleanup": "${KEEP_CHURN_JOBS}" != "1",
    },
    "objectCounts": counts,
    "artifacts": {
        "beforeJobs": str(root / f"${SCENARIO}.before.jobs.json"),
        "submittedJobs": str(root / f"${SCENARIO}.submitted.jobs.json"),
        "completedJobs": str(root / f"${SCENARIO}.completed.jobs.json"),
        "afterCleanupJobs": str(root / f"${SCENARIO}.after_cleanup.jobs.json"),
        "afterCleanupPods": str(root / f"${SCENARIO}.after_cleanup.pods.json"),
    },
    "status": status,
    "reasons": reasons,
}
(root / "${SCENARIO}.result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
print(f"${SCENARIO}: {status} jobs={created_jobs} completed={completed} failed={failed} remainingJobs={remaining_jobs} remainingPods={remaining_pods}")
PY

echo "result: ${result_json}"
