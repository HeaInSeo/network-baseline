# Network Baseline Operational Matrix

Date: 2026-06-05

## Matrix

| Scenario | Path | Protocol | Purpose |
|---|---|---|---|
| `service-tcp` | client Pod -> Service -> server Pod | TCP | default dataplane service path |
| `pod-direct-tcp` | client Pod -> server Pod IP | TCP | bypass Service routing |
| `pod-direct-udp` | client Pod -> server Pod IP | UDP | bypass Service routing for jitter/loss |
| `same-node-service-tcp` | client Pod -> Service -> server Pod on same node | TCP | best-case node-local service path |
| `cross-node-service-tcp` | client Pod -> Service -> server Pod on another node | TCP | remote_fetch-style service path |
| `service-udp` | client Pod -> Service -> server Pod | UDP | jitter/loss baseline |
| `fanout-tcp-5` | 5 clients -> Service | TCP | low fan-out pressure |
| `fanout-tcp-10` | 10 clients -> Service | TCP | medium fan-out pressure |
| `fanout-tcp-20` | 20 clients -> Service | TCP | high fan-out pressure |

## Required First Operational Profile

Minimum operational profile:

- `service-tcp`
- `service-udp`
- `pod-direct-tcp`
- `pod-direct-udp`
- `same-node-service-tcp`
- `cross-node-service-tcp`
- `fanout-tcp-5`

## Failure Interpretation

- `service-tcp` fails, direct Pod passes: Service/CNI/kube-proxy or provider-specific service path issue.
- direct Pod fails: Pod-to-Pod dataplane issue.
- `cross-node-service-tcp` fails, `same-node-service-tcp` passes: node-to-node network issue.
- `cross-node-service-tcp` is skipped: cluster does not have at least two schedulable nodes.
- UDP loss high, TCP okay: packet loss/jitter issue that may affect streaming or peer transfer.
- fan-out degrades heavily: concurrency or network saturation risk.
