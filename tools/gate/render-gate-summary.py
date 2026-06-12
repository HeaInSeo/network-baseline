#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


BLOCKING_STATUS = {"fail"}
MANUAL_REVIEW_STATUS = {"warn", "skipped"}


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def decision_for_status(status):
    normalized = str(status or "warn").lower()
    if normalized in BLOCKING_STATUS:
        return "block"
    if normalized in MANUAL_REVIEW_STATUS:
        return "manual-review"
    if normalized == "pass":
        return "pass"
    return "manual-review"


def scenario_name(result):
    scenario = result.get("scenario") or {}
    if scenario.get("name"):
        return scenario["name"]
    if result.get("schemaVersion") == "network-baseline.k8sgpt.v1":
        return "k8sgpt-analysis"
    return result.get("schemaVersion", "unknown")


def collect_artifacts(value):
    paths = []
    if isinstance(value, dict):
        artifacts = value.get("artifacts")
        if isinstance(artifacts, dict):
            paths.extend(str(path) for path in artifacts.values())
        for nested in value.values():
            paths.extend(collect_artifacts(nested))
    elif isinstance(value, list):
        for item in value:
            paths.extend(collect_artifacts(item))
    return paths


def result_reason(result):
    reasons = result.get("reasons") or []
    if reasons:
        return "; ".join(str(reason) for reason in reasons)
    for key in ("imagePull", "registry", "remoteFetch", "localReuse", "churn", "gc"):
        section = result.get(key)
        if isinstance(section, dict) and section.get("reason"):
            return str(section["reason"])
    return ""


def render_gate_summary(summary, run_dir):
    results = summary.get("results") or []
    scenario_results = []
    required_inputs_missing = []
    blocking = []
    manual_review = []

    for result in results:
        name = scenario_name(result)
        status = str(result.get("status", "warn")).lower()
        decision = decision_for_status(status)
        reason = result_reason(result)
        row = {
            "name": name,
            "type": (result.get("scenario") or {}).get("type") or result.get("schemaVersion", "-"),
            "status": status,
            "decision": decision,
            "reason": reason,
            "evidence": sorted(set(collect_artifacts(result))),
        }
        scenario_results.append(row)
        if decision == "block":
            blocking.append(name)
        elif decision == "manual-review":
            manual_review.append(name)
        if status == "skipped":
            required_inputs_missing.append(name)

    overall_status = str(summary.get("status", "warn")).lower()
    decision = decision_for_status(overall_status)
    if blocking:
        decision = "block"
    elif manual_review or required_inputs_missing:
        decision = "manual-review"

    return {
        "schemaVersion": "network-baseline.gateSummary.v1",
        "runId": summary.get("runId", "-"),
        "sourceSchemaVersion": summary.get("schemaVersion", "-"),
        "status": overall_status,
        "decision": decision,
        "artifactDirectory": str(run_dir),
        "summaryPath": str(Path(run_dir) / "genomic-environment-summary.json"),
        "reportPath": str(Path(run_dir) / "report.md"),
        "blockingScenarios": blocking,
        "manualReviewScenarios": manual_review,
        "requiredInputsMissing": sorted(set(required_inputs_missing)),
        "scenarioResults": scenario_results,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    summary = load_json(args.summary)
    gate_summary = render_gate_summary(summary, run_dir)
    out_path = Path(args.out) if args.out else run_dir / "gate-summary.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(gate_summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"gate-summary: {out_path} decision={gate_summary['decision']}")


if __name__ == "__main__":
    main()
