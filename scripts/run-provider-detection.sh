#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-baseline}"
RUN_ID="${RUN_ID:-provider-detection-$(date -u +%Y%m%dT%H%M%SZ)}"
SCENARIO="${SCENARIO:-provider-detection}"
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
  if "$@" >"${ARTIFACT_DIR}/${SCENARIO}.${name}.txt" 2>&1; then
    echo "pass" >"${ARTIFACT_DIR}/${SCENARIO}.${name}.status"
  else
    echo "fail" >"${ARTIFACT_DIR}/${SCENARIO}.${name}.status"
  fi
}

optional_snapshot() {
  local name="$1"
  shift
  if "$@" >"${ARTIFACT_DIR}/${SCENARIO}.${name}.txt" 2>&1; then
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

snapshot namespaces kubectl get namespaces -o json
snapshot crds kubectl get crds -o json
snapshot pods_all kubectl get pods -A -o json
snapshot services_all kubectl get services -A -o json
snapshot deployments_all kubectl get deployments -A -o json
snapshot daemonsets_all kubectl get daemonsets -A -o json
optional_snapshot gatewayclasses kubectl get gatewayclasses -o json
optional_snapshot ingressclasses kubectl get ingressclasses -o json

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - <<PY
import json
from pathlib import Path

artifact_dir = Path("${ARTIFACT_DIR}")

def load_snapshot(name):
    status_path = artifact_dir / f"${SCENARIO}.{name}.status"
    data_path = artifact_dir / f"${SCENARIO}.{name}.txt"
    status = status_path.read_text(encoding="utf-8").strip() if status_path.exists() else "fail"
    raw = data_path.read_text(encoding="utf-8", errors="replace") if data_path.exists() else ""
    if status != "pass":
        return {"status": status, "items": [], "raw": raw}
    try:
        parsed = json.loads(raw)
        return {"status": status, "items": parsed.get("items", []), "raw": raw}
    except json.JSONDecodeError:
        return {"status": "fail", "items": [], "raw": raw}

namespaces = load_snapshot("namespaces")
crds = load_snapshot("crds")
pods = load_snapshot("pods_all")
services = load_snapshot("services_all")
deployments = load_snapshot("deployments_all")
daemonsets = load_snapshot("daemonsets_all")
gatewayclasses = load_snapshot("gatewayclasses")
ingressclasses = load_snapshot("ingressclasses")

def names(items):
    return {item.get("metadata", {}).get("name", "") for item in items}

namespace_names = names(namespaces["items"])
crd_names = names(crds["items"])

def workload_names(snapshot):
    found = []
    for item in snapshot["items"]:
        metadata = item.get("metadata", {})
        found.append({
            "namespace": metadata.get("namespace", ""),
            "name": metadata.get("name", ""),
            "labels": metadata.get("labels", {}),
        })
    return found

def pods_with_container(container_name):
    found = []
    for item in pods["items"]:
        spec = item.get("spec", {})
        containers = spec.get("containers", [])
        if any(container.get("name") == container_name for container in containers):
            metadata = item.get("metadata", {})
            found.append({
                "namespace": metadata.get("namespace", ""),
                "name": metadata.get("name", ""),
                "node": spec.get("nodeName", ""),
            })
    return found

daemonset_names = workload_names(daemonsets)
deployment_names = workload_names(deployments)
service_names = workload_names(services)

def has_workload(workloads, name_substring=None, namespace=None):
    for workload in workloads:
        if namespace and workload["namespace"] != namespace:
            continue
        if name_substring and name_substring not in workload["name"]:
            continue
        return True
    return False

def provider(name, kind, detected, signals, status_if_detected="pass"):
    return {
        "name": name,
        "kind": kind,
        "detected": detected,
        "status": status_if_detected if detected else "skipped",
        "reasons": [] if detected else ["provider not detected"],
        "signals": signals,
    }

cilium_signals = {
    "namespace": "cilium" in namespace_names or "kube-system" in namespace_names,
    "daemonset": has_workload(daemonset_names, "cilium"),
    "ciliumCrds": sorted([name for name in crd_names if "cilium.io" in name]),
    "hubbleWorkload": has_workload(deployment_names, "hubble") or has_workload(service_names, "hubble"),
}
cilium_detected = bool(cilium_signals["daemonset"] or cilium_signals["ciliumCrds"])

istio_signals = {
    "namespace": "istio-system" in namespace_names,
    "istiodDeployment": has_workload(deployment_names, "istiod", "istio-system"),
    "sidecarPods": pods_with_container("istio-proxy"),
    "istioCrds": sorted([name for name in crd_names if "istio.io" in name]),
}
istio_detected = bool(istio_signals["namespace"] or istio_signals["istiodDeployment"] or istio_signals["sidecarPods"] or istio_signals["istioCrds"])

linkerd_signals = {
    "namespace": "linkerd" in namespace_names,
    "controlPlaneDeployment": has_workload(deployment_names, "linkerd", "linkerd"),
    "sidecarPods": pods_with_container("linkerd-proxy"),
    "linkerdCrds": sorted([name for name in crd_names if "linkerd.io" in name]),
}
linkerd_detected = bool(linkerd_signals["namespace"] or linkerd_signals["sidecarPods"] or linkerd_signals["linkerdCrds"])

calico_signals = {
    "namespace": "calico-system" in namespace_names,
    "calicoNodeDaemonSet": has_workload(daemonset_names, "calico-node"),
    "calicoCrds": sorted([name for name in crd_names if "projectcalico.org" in name]),
}
calico_detected = bool(calico_signals["namespace"] or calico_signals["calicoNodeDaemonSet"] or calico_signals["calicoCrds"])

gateway_signals = {
    "gatewayApiCrds": sorted([name for name in crd_names if "gateway.networking.k8s.io" in name]),
    "gatewayClasses": [item.get("metadata", {}).get("name", "") for item in gatewayclasses["items"]],
    "ingressClasses": [item.get("metadata", {}).get("name", "") for item in ingressclasses["items"]],
}
gateway_detected = bool(gateway_signals["gatewayApiCrds"] or gateway_signals["gatewayClasses"] or gateway_signals["ingressClasses"])

providers = [
    provider("cilium", "cni", cilium_detected, cilium_signals),
    provider("istio", "mesh", istio_detected, istio_signals),
    provider("linkerd", "mesh", linkerd_detected, linkerd_signals),
    provider("calico", "cni", calico_detected, calico_signals),
    provider("gateway-api-or-ingress", "gateway", gateway_detected, gateway_signals),
]

snapshot_statuses = {
    name: load_snapshot(name)["status"]
    for name in [
        "namespaces",
        "crds",
        "pods_all",
        "services_all",
        "deployments_all",
        "daemonsets_all",
        "gatewayclasses",
        "ingressclasses",
    ]
}

status = "pass"
reasons = []
if any(value == "fail" for value in snapshot_statuses.values()):
    status = "warn"
    reasons.append("one or more provider detection snapshots could not be collected")

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
        "type": "provider-detection",
    },
    "providers": providers,
    "snapshots": snapshot_statuses,
    "status": status,
    "reasons": reasons,
}
Path("${result_json}").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
detected = [provider["name"] for provider in providers if provider["detected"]]
print(f"${SCENARIO}: {status} detected={','.join(detected) if detected else 'none'}")
PY

echo "result: ${result_json}"
