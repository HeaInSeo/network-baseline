# Network Baseline Operational Matrix

Date: 2026-06-05

## Matrix

| Scenario | Path | Protocol | Purpose |
|---|---|---|---|
| `service-tcp` | client Pod -> Service -> server Pod | TCP | default dataplane service path |
| `direct-pod-tcp` | client Pod -> server Pod IP | TCP | bypass Service routing |
| `same-node-tcp` | same-node Pod pair | TCP | best-case node-local network path |
| `cross-node-tcp` | cross-node Pod pair | TCP | remote_fetch-style path |
| `service-udp` | client Pod -> Service -> server Pod | UDP | jitter/loss baseline |
| `fanout-tcp-5` | 5 clients -> Service | TCP | low fan-out pressure |
| `fanout-tcp-10` | 10 clients -> Service | TCP | medium fan-out pressure |
| `fanout-tcp-20` | 20 clients -> Service | TCP | high fan-out pressure |

## Required First Operational Profile

Minimum operational profile:

- `service-tcp`
- `cross-node-tcp`
- `service-udp`
- `fanout-tcp-5`

## Failure Interpretation

- `service-tcp` fails, direct Pod passes: Service/CNI/kube-proxy/Cilium path issue.
- direct Pod fails: Pod-to-Pod dataplane issue.
- cross-node fails, same-node passes: node-to-node network issue.
- UDP loss high, TCP okay: packet loss/jitter issue that may affect streaming or peer transfer.
- fan-out degrades heavily: concurrency or network saturation risk.

