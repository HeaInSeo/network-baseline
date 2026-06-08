# 원격 VM infra-lab 실행 Runbook

작성일: 2026-06-06

## 목적

`network-baseline`은 실제 Kubernetes Job을 만들어 네트워크/환경 baseline을 측정한다.
현재 랩 클러스터는 원격 VM 환경에서 실행되며, VM/K8s lifecycle의 source of truth는
`infra-lab` GitHub repo다.

이 문서는 `network-baseline`을 `infra-lab` 기반 원격 VM K8s 환경에서 실행하는
절차와 bori 통합 관점을 정리한다.

## 역할 분리

`infra-lab`:

- 원격 VM lifecycle
- kubeadm cluster bootstrap
- CNI/addon 설치
- kubeconfig/state 관리
- `ilab` 기반 read-only 상태 조회

`network-baseline`:

- K8s network/environment preflight 실행
- iperf3 throughput baseline
- DNS/Service/NetworkPolicy/MTU smoke check
- result artifact 생성
- K8s 리소스 적용 후 K8sGPT CLI 진단 artifact 생성

`bori`:

- 어느 release/app/environment에 baseline을 적용할지 결정
- baseline 결과를 rollout/promotion gate로 소비
- 향후 operator/CRD status에 반영

## Source Of Truth

`infra-lab`은 GitHub가 source of truth다.

```text
https://github.com/HeaInSeo/infra-lab
```

`network-baseline` 작업 중 infra-lab의 VM lifecycle 스크립트나 환경 profile을 임의로
수정하지 않는다. infra-lab 변경이 필요하면 infra-lab repo에서 별도 작업으로 진행한다.

## 사전 확인

원격 랩 상태 확인:

```bash
cd /opt/go/src/github.com/HeaInSeo/infra-lab
HOST_PROFILE=hosts/remote-lab.env ./scripts/k8s-tool.sh status
```

또는 `ilab` 사용:

```bash
cd /opt/go/src/github.com/HeaInSeo/infra-lab
make build
./bin/ilab doctor
./bin/ilab k8s status
```

## kubeconfig 지정

bori의 `environments/infra-lab/environment.yaml`은 `KUBECONFIG` 환경변수를 사용한다.
`network-baseline`도 같은 방식으로 실행한다.

예시:

```bash
export KUBECONFIG=/opt/go/src/github.com/HeaInSeo/infra-lab/state/<env>/kubeconfig
kubectl get nodes -o wide
```

원격 host 내부에서 실행한다면, 원격 host에 있는 infra-lab state 경로를 기준으로 지정한다.

## network-baseline 실행

```bash
cd /opt/go/src/github.com/HeaInSeo/network-baseline
make validate
./scripts/run-network-baseline-matrix.sh
```

`run-network-baseline-matrix.sh`는 K8s 리소스를 적용하고 Job을 실행한 뒤
마지막 단계에서 반드시 K8sGPT CLI 진단을 실행한다.

```bash
./scripts/run-k8sgpt-analysis.sh
```

기본 범위는 `network-baseline` namespace다. 클러스터 전체 진단이 필요하면
아래처럼 명시한다.

```bash
K8SGPT_SCOPE=cluster ./scripts/run-k8sgpt-analysis.sh
```

운영 규칙:

- K8s 리소스를 적용하거나 K8s 연동 테스트를 수행한 run은 K8sGPT artifact를 남겨야 한다.
- `k8sgpt analyze`가 실패하면 run도 실패로 취급한다.
- `--explain`은 기본으로 사용하지 않는다. AI backend 없이 Kubernetes 상태와 Event 기반 진단만 수행한다.
- K8sGPT 결과는 app 로그를 대체하지 않는다. CrashLoopBackOff, ImagePullBackOff, Pending,
  Service endpoint 문제 같은 리소스 상태 진단 evidence로 사용한다.

개별 실행:

```bash
./scripts/run-network-health-checks.sh
./scripts/run-network-policy-checks.sh
./scripts/run-mtu-smoke-check.sh
./scripts/run-network-baseline-fanout.sh
./scripts/run-k8sgpt-analysis.sh
```

MTU smoke size 조정:

```bash
PING_PAYLOAD_SIZES="1200 1400 1472 8972" ./scripts/run-mtu-smoke-check.sh
```

## 산출물

```text
artifacts/network-baseline/<run-id>/
  matrix-summary.json
  dns-service-discovery.result.json
  networkpolicy-allow-deny.result.json
  mtu-smoke.result.json
  service-tcp.result.json
  service-udp.result.json
  pod-direct-tcp.result.json
  pod-direct-udp.result.json
  same-node-service-tcp.result.json
  cross-node-service-tcp.result.json
  fanout-tcp-5.result.json
  k8sgpt-analysis.json
  k8sgpt-analysis.txt
  k8sgpt-analysis.stderr
  k8sgpt-analysis.summary.json
```

## bori 연결 관점

bori는 이미 `infra-lab` environment를 가지고 있다.

```text
bori/environments/infra-lab/environment.yaml
```

향후 연결 방향:

```text
bori verify/deploy
  -> environment=infra-lab
  -> network-baseline matrix 실행
  -> matrix-summary.json 수집
  -> pass/warn/fail/skipped를 promotion decision에 반영
```

초기에는 bori가 `network-baseline` CLI/script를 shell adapter로 호출하는 방식이 가장
단순하다. 이후 `NetworkBaselineRun` CRD 또는 bori operator status condition으로
승격할 수 있다.

## 현재 제약

- 이 repo의 현재 로컬 shell에서는 kube context가 설정되어 있지 않다.
- 실제 Job 실행 검증은 원격 VM host 또는 올바른 `KUBECONFIG`가 설정된 환경에서 진행해야 한다.
- `mtu-smoke`는 DF bit 기반의 정확한 path MTU discovery가 아니라 smoke check다.
- NetworkPolicy check는 CNI가 NetworkPolicy enforcement를 지원해야 의미가 있다.
