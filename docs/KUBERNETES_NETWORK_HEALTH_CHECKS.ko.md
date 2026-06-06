# Kubernetes 네트워크 운영 신호

작성일: 2026-06-06

## 목적

N2 단계는 iperf3 throughput만으로 설명되지 않는 Kubernetes 네트워크 운영 신호를
분리한다.

현재는 `dns-service-discovery`, `networkpolicy-allow-deny`, `mtu-smoke`,
`node-to-node-reachability`, `conntrack-snapshot` check를 지원한다.

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

### `mtu-smoke`

검증 항목:

- check Pod에서 iperf3 server Pod IP로 ICMP ping 실행
- 기본 payload size: `1200 1400 1472`
- payload size를 올려가며 기본적인 MTU/fragmentation 이상 여부 확인

실행:

```bash
./scripts/run-mtu-smoke-check.sh
```

원격 VM 기반 K8s 환경에서 size를 조정하려면:

```bash
PING_PAYLOAD_SIZES="1200 1400 1472 8972" ./scripts/run-mtu-smoke-check.sh
```

결과 파일:

```text
artifacts/network-baseline/<run-id>/mtu-smoke.result.json
artifacts/network-baseline/<run-id>/mtu-smoke.log
```

주의:

- 현재 구현은 smoke check다. DF bit 기반의 정확한 path MTU discovery가 아니다.
- ICMP가 차단된 환경에서는 MTU 문제가 아니어도 fail이 날 수 있다.
- 실패 시 CNI, VM NIC MTU, overlay MTU, node 간 경로, ICMP policy를 함께 본다.

### `node-to-node-reachability`

검증 항목:

- DaemonSet으로 각 노드에 check Pod 배치
- 각 check Pod에서 다른 check Pod IP로 ICMP ping 실행
- source node, target node, target Pod IP, exit code를 artifact로 기록

실행:

```bash
./scripts/run-node-reachability-check.sh
```

결과 파일:

```text
artifacts/network-baseline/<run-id>/node-to-node-reachability.result.json
artifacts/network-baseline/<run-id>/node-to-node-reachability.log
artifacts/network-baseline/<run-id>/node-to-node-reachability.pods.json
```

주의:

- 단일 노드 환경에서는 `skipped`로 기록된다.
- ICMP가 차단된 환경에서는 node-to-node datapath 문제가 아니어도 fail이 날 수 있다.
- `KEEP_NODE_REACHABILITY_PODS=1`을 지정하면 디버깅용 Pod를 남긴다.

### `conntrack-snapshot`

검증 항목:

- DaemonSet으로 각 노드에 read-only snapshot Pod 배치
- host `/proc`를 read-only로 마운트
- `nf_conntrack_count`, `nf_conntrack_max` 수집
- count/max 기준 사용률을 계산해 warn/fail 판정

실행:

```bash
./scripts/run-conntrack-snapshot.sh
```

결과 파일:

```text
artifacts/network-baseline/<run-id>/conntrack-snapshot.result.json
artifacts/network-baseline/<run-id>/conntrack-snapshot.raw/<node>.log
```

판정 기준:

- 사용률 70% 이상: `warn`
- 사용률 90% 이상: `fail`
- count/max를 읽을 수 없음: `warn`

주의:

- 이 check는 노드 상태를 변경하지 않는 read-only snapshot이다.
- host `/proc` 마운트를 사용하므로 운영 정책상 허용 여부를 확인해야 한다.
- Cilium 환경에서는 Hubble/Cilium drop signal과 함께 해석해야 한다.

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
- `mtu-smoke=fail`:
  VM NIC MTU, CNI overlay MTU, node 간 경로, ICMP 허용 여부를 본다.
- `node-to-node-reachability=fail`:
  node 간 라우팅, CNI overlay, 방화벽, ICMP policy를 본다.
- `conntrack-snapshot=warn/fail`:
  fan-out, DNS/Service churn, short-lived connection 폭증, kube-proxy/CNI conntrack 의존 경로를 본다.

## 다음 확장

- Cilium/Hubble datapath snapshot
