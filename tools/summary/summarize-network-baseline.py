#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def default_thresholds():
    return {
        "profiles": {
            "smoke": {
                "tcpBitsPerSecond": {"warnBelow": 100000000, "failBelow": 50000000},
                "udpBitsPerSecond": {"warnBelow": 50000000, "failBelow": 10000000},
                "retransmits": {"warnAbove": 100, "failAbove": 500},
                "udpLostPercent": {"warnAbove": 1, "failAbove": 5},
            },
            "operational": {
                "tcpBitsPerSecond": {"warnBelow": 500000000, "failBelow": 100000000},
                "udpBitsPerSecond": {"warnBelow": 100000000, "failBelow": 50000000},
                "retransmits": {"warnAbove": 50, "failAbove": 200},
                "udpLostPercent": {"warnAbove": 0.5, "failAbove": 2},
            },
        }
    }


def load_thresholds(path):
    thresholds = default_thresholds()
    policy_path = Path(path)
    if not policy_path.exists():
        return thresholds

    current_profile = None
    current_section = None
    profile_re = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
    section_re = re.compile(r"^    ([A-Za-z0-9_-]+):\s*$")
    value_re = re.compile(r"^      ([A-Za-z0-9_-]+):\s*([0-9.]+)\s*$")

    for line in policy_path.read_text(encoding="utf-8").splitlines():
        match = profile_re.match(line)
        if match:
            current_profile = match.group(1)
            thresholds["profiles"].setdefault(current_profile, {})
            current_section = None
            continue
        match = section_re.match(line)
        if match:
            current_section = match.group(1)
            if current_profile:
                thresholds["profiles"][current_profile].setdefault(current_section, {})
            continue
        match = value_re.match(line)
        if match:
            key, raw_value = match.groups()
            if current_profile and current_section:
                value = float(raw_value) if "." in raw_value else int(raw_value)
                thresholds["profiles"][current_profile][current_section][key] = value
    return thresholds


def tcp_metrics(iperf):
    end = iperf.get("end", {})
    total = end.get("sum_received") or end.get("sum") or {}
    sender = end.get("sum_sent") or {}
    bits = float(total.get("bits_per_second") or sender.get("bits_per_second") or 0)
    retransmits = int(sender.get("retransmits") or 0)
    return {
        "bitsPerSecond": bits,
        "bytesPerSecond": bits / 8,
        "retransmits": retransmits,
        "jitterMs": 0,
        "lostPercent": 0,
    }


def udp_metrics(iperf):
    end = iperf.get("end", {})
    total = end.get("sum") or {}
    bits = float(total.get("bits_per_second") or 0)
    return {
        "bitsPerSecond": bits,
        "bytesPerSecond": bits / 8,
        "retransmits": 0,
        "jitterMs": float(total.get("jitter_ms") or 0),
        "lostPercent": float(total.get("lost_percent") or 0),
    }


def evaluate(metrics, protocol, thresholds, profile_name):
    profile = thresholds["profiles"][profile_name]
    status = "pass"
    reasons = []
    throughput_key = "udpBitsPerSecond" if protocol == "udp" else "tcpBitsPerSecond"
    throughput = profile[throughput_key]
    if metrics["bitsPerSecond"] < throughput["failBelow"]:
        status = "fail"
        reasons.append("throughput below fail threshold")
    elif metrics["bitsPerSecond"] < throughput["warnBelow"] and status != "fail":
        status = "warn"
        reasons.append("throughput below warn threshold")
    if protocol == "tcp":
        retrans = profile["retransmits"]
        if metrics["retransmits"] > retrans["failAbove"]:
            status = "fail"
            reasons.append("retransmits above fail threshold")
        elif metrics["retransmits"] > retrans["warnAbove"] and status != "fail":
            status = "warn"
            reasons.append("retransmits above warn threshold")
    if protocol == "udp":
        loss = profile["udpLostPercent"]
        if metrics["lostPercent"] > loss["failAbove"]:
            status = "fail"
            reasons.append("UDP loss above fail threshold")
        elif metrics["lostPercent"] > loss["warnAbove"] and status != "fail":
            status = "warn"
            reasons.append("UDP loss above warn threshold")
    return status, reasons


parser = argparse.ArgumentParser()
parser.add_argument("--iperf-json", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--thresholds", default="policy/network-baseline-thresholds.yaml")
parser.add_argument("--profile", default="operational", choices=["smoke", "operational"])
parser.add_argument("--run-id", required=True)
parser.add_argument("--scenario", required=True)
parser.add_argument("--protocol", default="tcp", choices=["tcp", "udp"])
parser.add_argument("--path", default="pod-service-pod")
parser.add_argument("--placement", default="any")
parser.add_argument("--namespace", default="network-baseline")
parser.add_argument("--server-pod", default="")
parser.add_argument("--server-node", default="")
parser.add_argument("--client-pod", default="")
parser.add_argument("--client-node", default="")
parser.add_argument("--started-at", default="")
parser.add_argument("--finished-at", default="")
args = parser.parse_args()

iperf = load_json(args.iperf_json)
thresholds = load_thresholds(args.thresholds)

metrics = udp_metrics(iperf) if args.protocol == "udp" else tcp_metrics(iperf)
status, reasons = evaluate(metrics, args.protocol, thresholds, args.profile)

result = {
    "schemaVersion": "network-baseline.v1",
    "runId": args.run_id,
    "startedAt": args.started_at,
    "finishedAt": args.finished_at,
    "cluster": {
        "namespace": args.namespace,
        "serverPod": args.server_pod,
        "serverNode": args.server_node,
        "clientPod": args.client_pod,
        "clientNode": args.client_node,
    },
    "scenario": {
        "name": args.scenario,
        "protocol": args.protocol,
        "path": args.path,
        "placement": args.placement,
    },
    "iperf3": iperf,
    "metrics": metrics,
    "status": status,
    "reasons": reasons,
}

Path(args.out).parent.mkdir(parents=True, exist_ok=True)
Path(args.out).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"{args.scenario}: {status} bitsPerSecond={metrics['bitsPerSecond']:.0f}")
