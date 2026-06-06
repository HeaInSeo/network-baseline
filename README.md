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

Artifacts are written under:

```text
artifacts/network-baseline/
```

## Repository Layout

```text
docs/
  BORI_OPERATOR_INTEGRATION_CONTRACT.ko.md
  NETWORK_BASELINE_OPERATIONAL_SPRINT_PLAN.ko.md
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
fixtures/
  iperf3-tcp.sample.json
  iperf3-udp.sample.json
  networkbaselinepolicy.sample.yaml
  networkbaselinerun.sample.yaml
  network-baseline-result.sample.json
policy/
  network-baseline-thresholds.yaml
scripts/
  run-network-baseline.sh
  run-network-baseline-matrix.sh
tools/summary/
  summarize-network-baseline.py
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

## Operational Exit Criteria

This baseline reaches operational readiness when:

- standalone TCP and UDP measurements are repeatable
- same-node, cross-node, service-path, and fan-out profiles are supported
- JSON result schema is stable
- thresholds are versioned
- summaries clearly distinguish pass, warn, and fail
- runbooks cover cleanup and failure triage
- dataplane apps can call this baseline before app-specific smoke tests
