# Dataplane App Integration Guide

Date: 2026-06-05

## Principle

Dataplane apps should run this network baseline before app-specific smoke tests
when network quality could affect the result.

## Recommended Flow

```text
network baseline
  -> app deployment readiness
  -> app smoke
  -> app-specific SLI summary
```

If network baseline fails, app smoke may still run for debugging, but the result
should not be treated as an app regression without network triage.

## JUMI/AH/nan

Use before:

- JUMI remote_fetch smoke
- same-node/local_reuse versus cross-node comparison
- large artifact materialization stress

Interpretation:

- low cross-node throughput can explain remote_fetch slowness
- service path degradation can explain AH resolver latency
- fan-out degradation can explain simultaneous child materialization failures

## tori

Use before:

- dataplane service fan-out tests
- service-to-service integration tests
- throughput-sensitive workload tests

## bori

bori should eventually consume this baseline as:

- install preflight
- operational gate
- periodic cluster health check
- rollout safety check before dataplane app upgrades

## Future Apps

Any Kubernetes dataplane app can depend on:

- result schema v1
- threshold policy
- matrix scenario names
- summary status values

