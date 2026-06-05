# Network Baseline Scope

Date: 2026-06-05

## Purpose

This baseline is a common Kubernetes dataplane network test suite. It is not
specific to JUMI or artifact-handoff. It should be reusable by any dataplane app
that runs workload Pods, Jobs, runtime helpers, or service-to-service traffic in
a Kubernetes cluster.

## Scope

Included:

- TCP throughput with `iperf3`
- UDP jitter/loss with `iperf3`
- same-node and cross-node placement where schedulable
- Service path measurements
- fan-out client measurements
- JSON result artifacts
- threshold-based summary
- operational runbook and cleanup guidance

Excluded:

- application-level correctness
- artifact digest verification
- genomic tool correctness
- storage backend benchmarking
- WAN benchmarking
- production traffic replay

## Operational Interpretation

This baseline answers:

- Is the Kubernetes dataplane network healthy enough for controlled workload
  tests?
- Did a failed app smoke likely fail because of network path quality?
- Is service routing significantly worse than direct Pod traffic?
- Does cross-node throughput degrade below an acceptable threshold?
- Does fan-out traffic create unacceptable loss or retransmit symptoms?

It does not answer:

- whether JUMI/AH/nan logic is correct
- whether a pipeline was lowered correctly
- whether BWA/GATK/Samtools output is biologically correct
- whether node-local artifact GC is safe

## Shared Dataplane Users

Expected consumers:

- JUMI remote_fetch smoke
- artifact-handoff resolver service-path smoke
- nan materialization stress tests
- tori dataplane apps
- bori operational gates
- future K8s genomic dataplane apps

## Baseline Principle

Network baseline should run before app-specific dataplane smoke tests. If this
baseline fails, application-level smoke failures should not be interpreted as
application regressions until the network issue is resolved.

