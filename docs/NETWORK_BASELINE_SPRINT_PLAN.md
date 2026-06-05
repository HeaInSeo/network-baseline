# Network Baseline Sprint Plan

Date: 2026-06-05

## Goal

Raise the network baseline from ad hoc testing to operational-grade Kubernetes
dataplane validation.

## Sprint N0 - Scope And Contract

Duration: 1 day

Deliverables:

- scope document
- result schema
- threshold policy
- operational matrix
- runbook skeleton

Exit criteria:

- all supported scenarios are named
- result schema is stable enough for downstream consumers
- thresholds can be versioned

## Sprint N1 - Standalone iperf3 Runner

Duration: 2-3 days

Deliverables:

- iperf3 server Deployment/Service
- iperf3 client Job
- single-run script
- TCP result collection
- artifact output layout

Exit criteria:

- direct TCP baseline is runnable with `kubectl`
- JSON result artifact is generated
- summary produces pass/warn/fail

## Sprint N2 - Operational Matrix

Duration: 3-5 days

Deliverables:

- same-node profile
- cross-node profile
- service-path profile
- UDP profile
- fan-out profile
- matrix summary

Exit criteria:

- each scenario is independently runnable
- failures are scenario-specific
- cleanup is idempotent

## Sprint N3 - Observability And Gates

Duration: 2-3 days

Deliverables:

- threshold policy refinement
- summary tool stabilization
- kube-slint compatible artifact shape
- gate-ready status output

Exit criteria:

- `collection=Complete` equivalent is represented
- `evaluation=Complete` equivalent is represented
- dataplane apps can consume result paths

## Sprint N4 - Dataplane App Integration

Duration: 2-3 days

Deliverables:

- integration guide
- JUMI/AH/nan example
- tori/bori future adapter notes
- CI/manual gate guidance

Exit criteria:

- app smoke can declare network baseline prerequisite
- app failure triage can separate network from app/runtime failures

## Operational Completion Criteria

The baseline is operational-grade when:

- same-node, cross-node, service, UDP, and fan-out scenarios are supported
- summary and thresholds are stable
- cleanup is safe and repeatable
- result artifacts are machine-readable
- runbook covers common failure cases
- app teams can adopt it without modifying baseline internals

