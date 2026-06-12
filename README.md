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
- registry and image pull readiness for Harbor primary / GHCR mirror paths
- remote artifact fetch, digest verification, and cleanup
- node-local same-node reuse without PVC
- Kubernetes Job churn and explicit GC/cleanup evidence
- K8sGPT findings after Kubernetes integration runs

## What This Does Not Claim

Passing this baseline does not prove that a genomic workflow is production
ready. It only proves that the selected Kubernetes network paths satisfy the
minimum operational network thresholds for the test window.

`skipped` scenarios are not treated as production success. If required inputs
such as Harbor/GHCR image references or artifact URLs are missing, the genomic
environment gate reports `manual-review`.

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

Run the genomic dataplane environment baseline:

```bash
./scripts/run-genomic-environment-baseline.sh
```

This produces:

```text
artifacts/network-baseline/<run-id>/genomic-environment-summary.json
artifacts/network-baseline/<run-id>/gate-summary.json
artifacts/network-baseline/<run-id>/report.md
```

`gate-summary.json` is the machine-readable artifact intended for bori or other
operator agents. Its `decision` field is one of:

- `pass`
- `manual-review`
- `block`

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
ARTIFACT_KIB=1024 \
  ./scripts/run-local-reuse-same-node-baseline.sh
CHURN_JOBS=20 \
  ./scripts/run-job-churn-gc-baseline.sh
```

Run the genomic baseline with operational inputs:

```bash
PRIMARY_IMAGE=harbor.example/heainseo/jumi@sha256:... \
MIRROR_IMAGE=ghcr.io/heainseo/jumi@sha256:... \
PRIMARY_REGISTRY_URL=https://harbor.example/v2/ \
MIRROR_REGISTRY_URL=https://ghcr.io/v2/ \
FETCH_URL=https://artifact-source.example/data.bin \
EXPECTED_SHA256=... \
CHURN_JOBS=20 \
  ./scripts/run-genomic-environment-baseline.sh
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
  OPERATIONAL_COMPLETION_STATUS.ko.md
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
  job-churn-gc-job.yaml
  local-reuse-same-node-job.yaml
  registry-connectivity-job.yaml
  remote-fetch-http-job.yaml
fixtures/
  genomic-environment-summary.sample.json
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
  run-local-reuse-same-node-baseline.sh
  run-job-churn-gc-baseline.sh
  run-genomic-environment-baseline.sh
tools/summary/
  summarize-network-baseline.py
tools/report/
  render-network-baseline-report.py
tools/gate/
  render-gate-summary.py
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

N6 app preflight integration is intentionally out of scope for the current
completion pass. Excluding N6, the implementation-side exit criteria are met:

- standalone TCP and UDP measurements are repeatable
- same-node, cross-node, service-path, and fan-out profiles are supported
- genomic environment checks cover image pull, registry connectivity, remote fetch, local reuse, and Job churn/GC
- PVC is not required for the node-local reuse baseline
- K8sGPT analysis is part of integration runs
- kube-linter is wired through GitHub Actions
- JSON summaries distinguish `pass`, `warn`, `fail`, and `skipped`
- `gate-summary.json` exposes `pass`, `manual-review`, and `block`
- Markdown reports are generated for operator review

## Remaining External Inputs

The remaining work is operational evidence collection, not N6 implementation.
These values must come from the deployment environment:

- Harbor primary image reference
- GHCR mirror image reference
- expected Harbor/GHCR digest relationship
- real artifact URL
- expected artifact SHA-256
- artifact size targets, such as 10MB, 100MB, and 1GiB+

Until those values are supplied, image pull, registry connectivity, and remote
fetch checks may be `skipped`, and the correct gate decision is
`manual-review`.
