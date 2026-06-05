# Network Baseline Result Schema

Date: 2026-06-05

## Top-Level Shape

```json
{
  "schemaVersion": "network-baseline.v1",
  "runId": "network-baseline-20260605T000000Z",
  "startedAt": "2026-06-05T00:00:00Z",
  "finishedAt": "2026-06-05T00:00:20Z",
  "cluster": {
    "namespace": "network-baseline",
    "serverPod": "iperf3-server-...",
    "serverNode": "worker-a",
    "clientPod": "iperf3-client-...",
    "clientNode": "worker-b"
  },
  "scenario": {
    "name": "service-tcp",
    "protocol": "tcp",
    "path": "pod-service-pod",
    "parallel": 1,
    "durationSeconds": 10
  },
  "iperf3": {},
  "metrics": {
    "bitsPerSecond": 900000000,
    "bytesPerSecond": 112500000,
    "retransmits": 2,
    "jitterMs": 0,
    "lostPercent": 0
  },
  "status": "pass"
}
```

## Required Fields

- `schemaVersion`
- `runId`
- `startedAt`
- `finishedAt`
- `cluster.namespace`
- `scenario.name`
- `scenario.protocol`
- `scenario.path`
- `metrics.bitsPerSecond`
- `status`

## Status Values

- `pass`: thresholds satisfied
- `warn`: usable but outside preferred operating band
- `fail`: below minimum threshold or collection failed
- `skipped`: scenario intentionally skipped

## Compatibility

The schema is intentionally flat enough to be consumed by:

- shell scripts
- Python summary tools
- kube-slint summary fixtures
- future bori operational gates

