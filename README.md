# network-baseline

Kubernetes dataplane network baseline toolkit.

This repository provides a reusable operational network baseline for Kubernetes
dataplane apps such as JUMI, artifact-handoff, nan-based runtime apps, tori, and
future bori-managed dataplane services.

The goal is to separate network/environment problems from application/runtime
problems before larger genomic workloads are tested.

## What This Measures

- Pod-to-Pod TCP throughput
- Pod-to-Service-to-Pod TCP throughput
- optional same-node and cross-node placement profiles
- optional UDP jitter/loss
- fan-out degradation
- namespace-level repeatability across controlled runs

## What This Does Not Claim

Passing this baseline does not prove that a genomic workflow is production
ready. It only proves that the selected Kubernetes network paths satisfy the
minimum operational network thresholds for the test window.

## Quick Start

```bash
kubectl create namespace network-baseline
./scripts/run-network-baseline.sh
```

Run the default matrix:

```bash
./scripts/run-network-baseline-matrix.sh
```

The default matrix currently includes:

- `service-tcp`
- `dns-service-discovery`
- `networkpolicy-allow-deny`
- `mtu-smoke`
- `node-to-node-reachability`
- `conntrack-snapshot`
- `provider-detection`
- `k8s-object-snapshot`
- `service-udp`
- `pod-direct-tcp`
- `pod-direct-udp`
- `same-node-service-tcp`
- `cross-node-service-tcp`
- `fanout-tcp-5`

Single-node clusters record `cross-node-service-tcp` as `skipped`.

Run one scenario:

```bash
SCENARIO=pod-direct-tcp ./scripts/run-network-baseline.sh
SCENARIO=pod-direct-udp ./scripts/run-network-baseline.sh
SCENARIO=same-node-service-tcp ./scripts/run-network-baseline.sh
SCENARIO=cross-node-service-tcp ./scripts/run-network-baseline.sh
SCENARIO=fanout-tcp-5 ./scripts/run-network-baseline-fanout.sh
SCENARIO=dns-service-discovery ./scripts/run-network-health-checks.sh
SCENARIO=networkpolicy-allow-deny ./scripts/run-network-policy-checks.sh
SCENARIO=mtu-smoke ./scripts/run-mtu-smoke-check.sh
SCENARIO=node-to-node-reachability ./scripts/run-node-reachability-check.sh
SCENARIO=conntrack-snapshot ./scripts/run-conntrack-snapshot.sh
SCENARIO=provider-detection ./scripts/run-provider-detection.sh
SCENARIO=k8s-object-snapshot ./scripts/run-k8s-object-snapshot.sh
PRIMARY_IMAGE=harbor.example/heainseo/jumi@sha256:... \
MIRROR_IMAGE=ghcr.io/heainseo/jumi@sha256:... \
  ./scripts/run-image-pull-baseline.sh
PRIMARY_REGISTRY_URL=https://harbor.example/v2/ \
MIRROR_REGISTRY_URL=https://ghcr.io/v2/ \
  ./scripts/run-registry-connectivity-baseline.sh
FETCH_URL=https://artifact-source.example/data.bin \
EXPECTED_SHA256=... \
  ./scripts/run-remote-fetch-http-baseline.sh
```

Any Kubernetes resource-apply or integration run must be followed by K8sGPT CLI
diagnosis. The matrix script runs it automatically:

```bash
./scripts/run-k8sgpt-analysis.sh
```

Artifacts are written under:

```text
artifacts/network-baseline/
```

## Repository Layout

```text
docs/
  BORI_OPERATOR_INTEGRATION_CONTRACT.ko.md
  GENOMIC_DATAPLANE_ENVIRONMENT_BASELINE.ko.md
  KUBERNETES_NETWORK_HEALTH_CHECKS.ko.md
  NETWORK_BASELINE_REPORTING.ko.md
  NETWORK_BASELINE_OPERATIONAL_SPRINT_PLAN.ko.md
  PROVIDER_NEUTRAL_OBSERVABILITY_BASELINE.ko.md
  REMOTE_VM_INFRA_LAB_RUNBOOK.ko.md
  NETWORK_BASELINE_SCOPE.md
  NETWORK_BASELINE_SPRINT_PLAN.md
  NETWORK_BASELINE_RESULT_SCHEMA.md
  NETWORK_BASELINE_OPERATIONAL_MATRIX.md
  DATAPLANE_APP_INTEGRATION_GUIDE.md
  NETWORK_BASELINE_RUNBOOK.md
deploy/iperf3/
  server.yaml
  client-job.yaml
deploy/crd/
  networkbaselinepolicy.yaml
  networkbaselinerun.yaml
deploy/checks/
  dns-service-job.yaml
deploy/genomic/
  image-pull-probe-pod.yaml
  registry-connectivity-job.yaml
  remote-fetch-http-job.yaml
fixtures/
  iperf3-tcp.sample.json
  iperf3-udp.sample.json
  matrix-summary.sample.json
  networkbaselinepolicy.sample.yaml
  networkbaselinerun.sample.yaml
  network-baseline-result.sample.json
policy/
  network-baseline-thresholds.yaml
scripts/
  run-network-baseline.sh
  run-network-baseline-matrix.sh
  run-network-baseline-fanout.sh
  run-network-health-checks.sh
  run-network-policy-checks.sh
  run-mtu-smoke-check.sh
  run-node-reachability-check.sh
  run-conntrack-snapshot.sh
  run-provider-detection.sh
  run-k8s-object-snapshot.sh
  run-k8sgpt-analysis.sh
  run-image-pull-baseline.sh
  run-registry-connectivity-baseline.sh
  run-remote-fetch-http-baseline.sh
  run-genomic-environment-baseline.sh
tools/summary/
  summarize-network-baseline.py
tools/report/
  render-network-baseline-report.py
```

## Local Validation

```bash
make validate
```

This validates shell syntax, compiles the summary tool, runs summary smoke tests
against bundled iperf3 fixtures, and renders the Kubernetes manifests through
Kustomize.

## Planning

The detailed Korean operational sprint plan is available at:

```text
docs/NETWORK_BASELINE_OPERATIONAL_SPRINT_PLAN.ko.md
```

The bori operator integration contract draft is available at:

```text
docs/BORI_OPERATOR_INTEGRATION_CONTRACT.ko.md
```

Generate a Markdown report from a matrix run:

```bash
python3 tools/report/render-network-baseline-report.py \
  --run-dir artifacts/network-baseline/<run-id>
```

## Operational Exit Criteria

This baseline reaches operational readiness when:

- standalone TCP and UDP measurements are repeatable
- same-node, cross-node, service-path, and fan-out profiles are supported
- JSON result schema is stable
- thresholds are versioned
- summaries clearly distinguish pass, warn, and fail
- runbooks cover cleanup and failure triage
- dataplane apps can call this baseline before app-specific smoke tests
