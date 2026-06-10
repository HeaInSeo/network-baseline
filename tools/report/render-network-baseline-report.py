#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


SEVERITY = {
    "pass": 0,
    "skipped": 1,
    "warn": 2,
    "fail": 3,
}


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def status_rank(status):
    return SEVERITY.get(str(status).lower(), 2)


def format_bps(value):
    try:
        bps = float(value)
    except (TypeError, ValueError):
        return "-"
    units = [
        ("Tbps", 1_000_000_000_000),
        ("Gbps", 1_000_000_000),
        ("Mbps", 1_000_000),
        ("Kbps", 1_000),
    ]
    for unit, scale in units:
        if bps >= scale:
            return f"{bps / scale:.2f} {unit}"
    return f"{bps:.0f} bps"


def extract_rows(results):
    rows = []
    for result in results:
        scenario = result.get("scenario", {})
        metrics = result.get("metrics", {})
        rows.append({
            "name": scenario.get("name", "-"),
            "type": scenario.get("type") or scenario.get("path", "-"),
            "protocol": scenario.get("protocol", "-"),
            "placement": scenario.get("placement", "-"),
            "status": result.get("status", "warn"),
            "throughput": format_bps(metrics.get("bitsPerSecond")),
            "reasons": ", ".join(result.get("reasons") or []),
        })
    rows.sort(key=lambda row: (status_rank(row["status"]), row["name"]), reverse=True)
    return rows


def genomic_rows(results):
    rows = []
    for result in results:
        scenario = result.get("scenario", {})
        name = scenario.get("name", "-")
        status = result.get("status", "warn")
        details = "-"
        evidence = []
        if "imagePull" in result:
            image_pull = result.get("imagePull") or {}
            primary = image_pull.get("primary") or {}
            mirror = image_pull.get("mirror") or {}
            details = (
                f"primary={primary.get('status', '-')} "
                f"mirror={mirror.get('status', '-')} "
                f"digestMatched={image_pull.get('digestMatched', False)}"
            )
        elif "registry" in result:
            registry = result.get("registry") or {}
            primary = registry.get("primary") or {}
            mirror = registry.get("mirror") or {}
            details = (
                f"primary={primary.get('status', '-')} http={primary.get('httpCode', '-')} "
                f"mirror={mirror.get('status', '-')}"
            )
        elif "remoteFetch" in result:
            remote_fetch = result.get("remoteFetch") or {}
            details = (
                f"bytes={remote_fetch.get('sizeBytes', 0)} "
                f"seconds={remote_fetch.get('fetchSeconds', 0)} "
                f"digestVerified={remote_fetch.get('digestVerified', False)} "
                f"cleanup={remote_fetch.get('cleanupObserved', False)}"
            )
        elif "localReuse" in result:
            local_reuse = result.get("localReuse") or {}
            details = (
                f"placement={local_reuse.get('placement', '-')} "
                f"node={local_reuse.get('nodeName', '-')} "
                f"digestVerified={local_reuse.get('digestVerified', False)} "
                f"cleanup={local_reuse.get('cleanupObserved', False)}"
            )
        elif "churn" in result or "gc" in result:
            churn = result.get("churn") or {}
            gc = result.get("gc") or {}
            details = (
                f"created={churn.get('jobsCreated', 0)} "
                f"completed={churn.get('jobsCompleted', 0)} "
                f"failed={churn.get('jobsFailed', 0)} "
                f"remainingJobs={gc.get('jobsRemaining', 0)} "
                f"remainingPods={gc.get('podsRemaining', 0)}"
            )
        elif result.get("schemaVersion") == "network-baseline.k8sgpt.v1":
            name = "k8sgpt-analysis"
            details = f"findings={result.get('findingCount', 0)} scope={result.get('scope', '-')}"

        for value in result.values():
            if isinstance(value, dict):
                artifacts = value.get("artifacts")
                if isinstance(artifacts, dict):
                    evidence.extend(str(path) for path in artifacts.values())
        rows.append({
            "name": name,
            "type": scenario.get("type") or result.get("schemaVersion", "-"),
            "status": status,
            "details": details,
            "reasons": ", ".join(result.get("reasons") or []),
            "evidence": "<br>".join(evidence[:3]) if evidence else "-",
        })
    rows.sort(key=lambda row: (status_rank(row["status"]), row["name"]), reverse=True)
    return rows


def provider_lines(results):
    for result in results:
        scenario = result.get("scenario", {})
        if scenario.get("name") != "provider-detection":
            continue
        providers = result.get("providers") or []
        if not providers:
            return ["- no provider data"]
        lines = []
        for provider in providers:
            detected = "detected" if provider.get("detected") else "not detected"
            lines.append(
                f"- {provider.get('name', '-')}: {provider.get('status', '-')}, {detected}"
            )
        return lines
    return ["- provider-detection result not found"]


def snapshot_lines(results):
    for result in results:
        scenario = result.get("scenario", {})
        if scenario.get("name") != "k8s-object-snapshot":
            continue
        counts = result.get("counts") or {}
        if not counts:
            return ["- no object snapshot counts"]
        return [f"- {key}: {value}" for key, value in sorted(counts.items())]
    return ["- k8s-object-snapshot result not found"]


def is_genomic_summary(summary):
    schema = summary.get("schemaVersion", "")
    return schema.startswith("network-baseline.genomicMatrix")


def gate_lines(summary):
    status = summary.get("status", "warn")
    if status == "pass":
        decision = "pass"
    elif status in {"warn", "skipped"}:
        decision = "manual-review"
    else:
        decision = "block"
    return [
        f"- Gate decision: `{decision}`",
        f"- Gate input: `{summary.get('schemaVersion', '-')}`",
        "- Machine-readable source: summary JSON in the same artifact directory",
    ]


def render(summary, run_dir):
    results = summary.get("results") or []
    lines = [
        "# Network Baseline Report",
        "",
        f"- Run ID: `{summary.get('runId', '-')}`",
        f"- Overall status: `{summary.get('status', '-')}`",
        f"- Artifact directory: `{run_dir}`",
        f"- Result count: `{len(results)}`",
        "",
        "## Gate Summary",
        "",
        *gate_lines(summary),
        "",
    ]
    if is_genomic_summary(summary):
        rows = genomic_rows(results)
        lines.extend([
            "## Genomic Environment Summary",
            "",
            "| Scenario | Type | Status | Details | Reasons | Evidence |",
            "|---|---|---|---|---|---|",
        ])
        for row in rows:
            lines.append(
                "| {name} | {type} | {status} | {details} | {reasons} | {evidence} |".format(**row)
            )
        lines.extend([
            "",
            "## Triage Order",
            "",
            "1. Check `fail` scenarios first.",
            "2. If image pull or registry connectivity failed, inspect Harbor primary before GHCR mirror.",
            "3. If remote fetch failed, inspect DNS/TCP/HTTP/digest/cleanup failure layer.",
            "4. If local reuse failed, inspect same-node placement, host path permissions, digest, and cleanup.",
            "5. If churn/GC failed, inspect pending/failed pods and remaining Job/Pod counts.",
            "6. Review K8sGPT findings before treating the run as operationally clean.",
            "",
        ])
        return "\n".join(lines)

    rows = extract_rows(results)
    lines.extend([
        "## Scenario Summary",
        "",
        "| Scenario | Type/Path | Protocol | Placement | Status | Throughput | Reasons |",
        "|---|---|---|---|---|---:|---|",
    ])
    for row in rows:
        lines.append(
            "| {name} | {type} | {protocol} | {placement} | {status} | {throughput} | {reasons} |".format(**row)
        )
    lines.extend([
        "",
        "## Providers",
        "",
        *provider_lines(results),
        "",
        "## Kubernetes Object Snapshot",
        "",
        *snapshot_lines(results),
        "",
        "## Triage Order",
        "",
        "1. Check `fail` scenarios before throughput numbers.",
        "2. If DNS/Service discovery failed, inspect DNS and Service routing first.",
        "3. If NetworkPolicy failed, inspect policy enforcement and selectors.",
        "4. If node reachability or MTU failed, inspect VM network, CNI overlay, and firewall paths.",
        "5. If conntrack warned or failed, inspect connection churn and short-lived fan-out patterns.",
        "6. If core checks pass but throughput fails, inspect CNI/service datapath and node placement.",
        "",
    ])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--summary", default="")
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    summary_path = Path(args.summary) if args.summary else run_dir / "matrix-summary.json"
    out_path = Path(args.out) if args.out else run_dir / "report.md"

    summary = load_json(summary_path)
    report = render(summary, run_dir)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(report + "\n", encoding="utf-8")
    print(f"report: {out_path}")


if __name__ == "__main__":
    main()
