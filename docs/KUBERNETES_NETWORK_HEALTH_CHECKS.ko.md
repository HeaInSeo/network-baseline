# Kubernetes 네트워크 운영 신호

작성일: 2026-06-06

## 목적

N2 단계는 iperf3 throughput만으로 설명되지 않는 Kubernetes 네트워크 운영 신호를
분리한다.

첫 구현은 `dns-service-discovery` check다.

## 현재 지원 항목

### `dns-service-discovery`

검증 항목:

- short service name DNS lookup
- FQDN service name DNS lookup
- short service name TCP connect
- FQDN service name TCP connect

대상 기본값:

```text
service: iperf3-server
namespace: network-baseline
port: 5201
```

실행:

```bash
./scripts/run-network-health-checks.sh
```

matrix 실행 시에도 먼저 포함된다.

```bash
./scripts/run-network-baseline-matrix.sh
```

## 결과 파일

```text
artifacts/network-baseline/<run-id>/dns-service-discovery.result.json
artifacts/network-baseline/<run-id>/dns-service-discovery.log
```

result schema:

```text
network-baseline.health.v1
```

## 해석

- `dns-service-discovery=fail`, iperf3도 fail:
  DNS/Service discovery 문제를 먼저 본다.
- `dns-service-discovery=pass`, iperf3 fail:
  DNS보다는 datapath, CNI, Service routing, node-to-node 경로를 본다.
- short name은 fail이고 FQDN은 pass:
  Pod namespace, search domain, DNS config를 본다.
- DNS는 pass이고 TCP connect가 fail:
  Service selector, endpoint, NetworkPolicy, kube-proxy/Cilium service path를 본다.

## 다음 확장

- NetworkPolicy allow/deny
- MTU/fragmentation smoke
- node-to-node reachability
- conntrack pressure snapshot
