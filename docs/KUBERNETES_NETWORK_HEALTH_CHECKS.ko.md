# Kubernetes 네트워크 운영 신호

작성일: 2026-06-06

## 목적

N2 단계는 iperf3 throughput만으로 설명되지 않는 Kubernetes 네트워크 운영 신호를
분리한다.

현재는 `dns-service-discovery`, `networkpolicy-allow-deny` check를 지원한다.

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

### `networkpolicy-allow-deny`

검증 항목:

- iperf3 server Pod에 ingress default deny NetworkPolicy 적용
- `networkpolicy-allow-check` client는 allow policy로 연결 가능해야 함
- allow policy 제거 후 `networkpolicy-deny-check` client는 연결이 차단되어야 함

실행:

```bash
./scripts/run-network-policy-checks.sh
```

matrix 실행 시에도 포함된다.

```bash
./scripts/run-network-baseline-matrix.sh
```

결과 파일:

```text
artifacts/network-baseline/<run-id>/networkpolicy-allow-deny.result.json
artifacts/network-baseline/<run-id>/networkpolicy-allow-deny.allow.log
artifacts/network-baseline/<run-id>/networkpolicy-allow-deny.deny.log
```

주의:

- 이 스크립트는 테스트 중 NetworkPolicy를 만들고 종료 시 삭제한다.
- deny check가 연결되면 `fail`이다. 이는 NetworkPolicy가 적용되지 않았거나
  CNI가 policy enforcement를 제공하지 않는 상황일 수 있다.

## 해석

- `dns-service-discovery=fail`, iperf3도 fail:
  DNS/Service discovery 문제를 먼저 본다.
- `dns-service-discovery=pass`, iperf3 fail:
  DNS보다는 datapath, CNI, Service routing, node-to-node 경로를 본다.
- short name은 fail이고 FQDN은 pass:
  Pod namespace, search domain, DNS config를 본다.
- DNS는 pass이고 TCP connect가 fail:
  Service selector, endpoint, NetworkPolicy, kube-proxy/Cilium service path를 본다.
- `networkpolicy-allow-deny=fail`, allow check 실패:
  policy selector, endpoint, Service path를 먼저 본다.
- `networkpolicy-allow-deny=fail`, deny check 실패:
  CNI NetworkPolicy enforcement 또는 policy 적용 상태를 본다.

## 다음 확장

- MTU/fragmentation smoke
- node-to-node reachability
- conntrack pressure snapshot
