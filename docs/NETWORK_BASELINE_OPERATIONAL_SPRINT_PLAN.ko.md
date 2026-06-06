# Network Baseline 운영 수준 스프린트 계획

작성일: 2026-06-06

## 목적

`network-baseline`을 단순 iperf3 실행 도구가 아니라, Kubernetes 기반
유전체 분석 dataplane app을 운영 환경에 올리기 전에 사용할 수 있는
네트워크/환경 preflight 기준선으로 확장한다.

이 문서는 작업이 중간에 멈추더라도 다음 작업자가 바로 이어받을 수 있도록
현재 상태, 완료 기준, 스프린트 순서, 산출물, 검증 방법을 함께 기록한다.

## 현재 상태

현재 버전: `v0.1.0`

이미 완료된 항목:

- 독립 GitHub repo 생성: `HeaInSeo/network-baseline`
- 기본 iperf3 server Deployment/Service 추가
- 기본 iperf3 client Job 추가
- TCP/UDP 단일 실행 스크립트 추가
- 기본 matrix 실행 스크립트 추가
- `smoke`, `operational` threshold profile 추가
- iperf3 JSON 요약기 추가
- `pass`, `warn`, `fail` 결과 판정 추가
- JSON result artifact schema 초안 추가
- runbook, scope, integration guide 초안 추가
- `make validate` 로컬 검증 추가

현재 검증 가능한 명령:

```bash
cd /opt/go/src/github.com/HeaInSeo/network-baseline
make validate
./scripts/run-network-baseline-matrix.sh
```

현재 한계:

- Pod IP 직접 경로는 `pod-direct-tcp`, `pod-direct-udp`로 1차 구현됨
- same-node, cross-node 배치 고정은 TCP service 경로 기준으로 1차 구현됨
- fan-out 부하 테스트는 `fanout-tcp-5`로 1차 구현됨
- DNS, Service discovery는 `dns-service-discovery`로 1차 구현됨
- NetworkPolicy allow/deny는 `networkpolicy-allow-deny`로 1차 구현됨
- MTU/fragmentation smoke는 `mtu-smoke`로 1차 구현됨
- node-to-node reachability는 `node-to-node-reachability`로 1차 구현됨
- conntrack snapshot은 `conntrack-snapshot`으로 1차 구현됨
- provider-neutral observability baseline은 문서화됨
- CNI/mesh/gateway provider detection은 `provider-detection`으로 1차 구현됨
- core Kubernetes object snapshot은 `k8s-object-snapshot`으로 1차 구현됨
- 큰 이미지 pull, registry, 대용량 데이터 경로 baseline은 아직 없음
- CLI 단일 바이너리나 operator/CRD 형태는 아직 없음

## 운영 기준 정의

이 프로젝트가 운영팀 기준으로 유효하려면 다음 질문에 답할 수 있어야 한다.

- 클러스터 네트워크가 dataplane app 실행 전에 최소 기준을 만족하는가?
- 네트워크 문제와 app/runtime 문제를 분리할 수 있는가?
- 변경 전/후 회귀를 artifact로 비교할 수 있는가?
- 같은 테스트를 여러 환경에서 반복 실행할 수 있는가?
- 실패 시 운영자가 어떤 층을 봐야 하는지 알 수 있는가?
- JUMI, AH, nan, tori, 향후 bori-managed app이 공통 preflight로 사용할 수 있는가?

## 전체 일정 요약

권장 일정:

```text
운영 preflight MVP:       4주
운영 반복 사용 가능:      6주
bori/operator 연동 기반:  8주
운영 제품 수준:          10-12주
```

현재는 `v0.1.0`으로 1주차 초입 산출물이 만들어진 상태다. 다음 작업은
`N1`부터 이어가면 된다.

## Sprint N1 - 기본 네트워크 경로 안정화

기간: 3-5일

목표:

기본 iperf3 측정을 운영 기준선으로 신뢰할 수 있게 만든다.

작업 항목:

- Pod IP 직접 TCP 측정 추가
- Pod IP 직접 UDP 측정 추가
- Service 경로 TCP/UDP 기존 구현 정리
- same-node 배치 고정 추가
- cross-node 배치 고정 추가
- node selector 또는 affinity 기반 scenario 입력 추가
- 실행 전 cluster/node snapshot 저장
- 실행 후 Job/Pod/Service cleanup idempotency 확인
- artifact 디렉터리 구조 고정

예상 산출물:

- `deploy/iperf3/direct-client-job.yaml`
- `scripts/run-network-baseline.sh` scenario 확장
- `scripts/run-network-baseline-matrix.sh` matrix 확장
- `artifacts/network-baseline/<run-id>/cluster-snapshot.json`
- `artifacts/network-baseline/<run-id>/node-snapshot.json`

완료 기준:

- `service-tcp`, `service-udp`, `pod-direct-tcp`, `pod-direct-udp` 실행 가능
- same-node/cross-node scenario가 독립적으로 실행 가능
- 실패가 scenario별 result JSON에 분리되어 기록됨
- cleanup을 여러 번 실행해도 실패하지 않음

검증 명령:

```bash
make validate
./scripts/run-network-baseline-matrix.sh
```

## Sprint N2 - Kubernetes 네트워크 운영 신호 추가

기간: 5일

목표:

단순 throughput뿐 아니라 Kubernetes 네트워크 운영에서 자주 문제가 되는
DNS, Service discovery, NetworkPolicy, MTU, node reachability를 preflight에
포함한다.

작업 항목:

- DNS lookup Job 추가
- Service DNS resolution 확인
- ClusterIP reachability 확인
- NetworkPolicy allow scenario 추가
- NetworkPolicy deny scenario 추가
- MTU/fragmentation smoke check 추가
- node-to-node reachability snapshot 추가
- conntrack 관련 관측 가능 항목 조사

예상 산출물:

- `deploy/checks/dns-job.yaml`
- `deploy/checks/networkpolicy-allow.yaml`
- `deploy/checks/networkpolicy-deny.yaml`
- `docs/KUBERNETES_NETWORK_HEALTH_CHECKS.ko.md`
- `tools/summary/summarize-k8s-network-health.py` 또는 기존 summary 확장

완료 기준:

- DNS failure와 throughput failure를 분리해서 볼 수 있음
- NetworkPolicy allow/deny가 expected result로 표현됨
- 운영자가 실패 원인을 최소한 DNS/Service/Policy/throughput 층으로 나눌 수 있음

검증 명령:

```bash
./scripts/run-network-health-checks.sh
```

## Sprint N3 - Provider-neutral observability baseline

기간: 5-7일

목표:

특정 CNI/mesh/gateway에 의존하지 않는 관측 기준을 만들고, Cilium/Istio/Linkerd/Calico
같은 provider는 선택 snapshot으로 수집한다.

작업 항목:

- provider detection 구현 완료
- core Kubernetes object snapshot 수집 완료
- CNI provider 감지
- mesh provider 감지
- gateway/ingress provider 감지
- Cilium optional snapshot 수집
- Istio optional snapshot 수집
- provider 미감지 환경에서는 skip reason 기록

예상 산출물:

- `scripts/run-provider-detection.sh`
- `docs/PROVIDER_NEUTRAL_OBSERVABILITY_BASELINE.ko.md`
- result JSON 내 `providers` section
- optional provider artifact

완료 기준:

- CNI/mesh/gateway가 없어도 core baseline은 실패하지 않음
- provider가 감지되지 않으면 `skipped`로 표현됨
- provider가 감지되면 기본 상태 snapshot이 artifact로 남음
- bori가 provider result를 optional gate evidence로 소비할 수 있음

검증 명령:

```bash
./scripts/run-provider-detection.sh
```

## Sprint N4 - 유전체 워크로드 환경 baseline

기간: 5-7일

목표:

유전체 분석 app의 실제 운영 병목인 큰 이미지, registry, remote fetch,
node-local reuse, fan-out churn을 baseline에 포함한다.

중요 제약:

- PVC는 사용하지 않는다.
- shared PVC 기반 storage benchmark는 이 스프린트 범위에서 제외한다.
- object storage는 필수 전제가 아니라 선택 transport/backend 후보로만 취급한다.
- JUMI service image와 nan/runtime/tool image를 혼동하지 않는다.
- AH는 Kubernetes Job/Pod를 생성하지 않고, placement/materialization 결정을 제공한다.
- JUMI가 Job/Pod 생성과 nan runtime context/env 주입을 담당한다.
- nan은 컨테이너 내부 runtime shim이며, Kubernetes API나 AH API를 직접 호출하지 않는다.

작업 항목:

- 큰 컨테이너 이미지 pull 시간 측정
- registry 접근성 측정
- registry pull 실패/지연 artifact 기록
- remote_fetch HTTP 경로 baseline 추가
- remote_fetch digest verification 결과 기록
- same-node node-local local_reuse 경로 baseline 추가
- node-local path/CAS 가용성 및 cleanup evidence 기록
- 대용량 HTTP fetch baseline 추가
- 병렬 Job fan-out scenario 추가
- Job 완료 후 TTL/GC 상태 기록
- Pod churn 시 DNS/CNI/API server 영향 기록

예상 산출물:

- `docs/GENOMIC_DATAPLANE_ENVIRONMENT_BASELINE.ko.md`
- `deploy/genomic/image-pull-job.yaml`
- `deploy/genomic/remote-fetch-http-job.yaml`
- `deploy/genomic/local-reuse-same-node-job.yaml`
- `deploy/fanout/fanout-client-job.yaml`
- `scripts/run-genomic-environment-baseline.sh`
- result JSON 내 `imagePull`, `registry`, `remoteFetch`, `localReuse`, `fanout`, `gc` section

완료 기준:

- 큰 이미지 pull 병목과 네트워크 throughput 병목을 분리 가능
- registry/image pull 병목과 Pod network 병목을 분리 가능
- remote_fetch 실패를 DNS/Service/HTTP/digest 층으로 분리 가능
- local_reuse 실패를 placement/node-local path/cleanup 층으로 분리 가능
- 병렬 Job 증가에 따른 warn/fail 기준이 존재
- 운영자가 app 실행 전에 환경 적합성을 판단할 수 있음

검증 명령:

```bash
./scripts/run-genomic-environment-baseline.sh
```

## Sprint N5 - 운영 UX와 리포트

기간: 1-2주

목표:

운영자가 반복 실행하고 결과를 쉽게 공유할 수 있는 UX를 만든다.

작업 항목:

- 단일 CLI 방향 결정
- `run`, `collect`, `summarize`, `cleanup` 명령 구조 정의
- Markdown report 생성
- JSON summary 안정화
- 과거 run과 현재 run 비교
- threshold profile 문서화
- 실패 triage message 개선
- CI/manual gate 사용 예시 추가

예상 산출물:

- `cmd/network-baseline` 또는 shell 기반 transitional CLI
- `docs/REPORTING_AND_GATE_UX.ko.md`
- `artifacts/network-baseline/<run-id>/report.md`
- `artifacts/network-baseline/<run-id>/matrix-summary.json`

완료 기준:

- 운영자가 한 명령으로 실행/요약/리포트 생성 가능
- 결과를 PR, 이슈, 운영 보고서에 붙일 수 있음
- app 팀이 `pass/warn/fail`만으로 gate 판단 가능

권장 CLI 형태:

```bash
network-baseline run matrix
network-baseline summarize artifacts/network-baseline/<run-id>
network-baseline cleanup --run-id <run-id>
```

## Sprint N6 - Dataplane app preflight 연동

기간: 1주

목표:

JUMI, AH, nan, tori 같은 dataplane app 테스트 전에 공통 preflight로 사용할 수
있게 만든다.

작업 항목:

- JUMI smoke 전 baseline 실행 예시 추가
- AH smoke 전 baseline 실행 예시 추가
- nan runtime test 전 baseline 실행 예시 추가
- tori future integration note 추가
- app-specific threshold override 구조 정의
- 실패 시 app smoke를 중단하는 gate 예시 추가

예상 산출물:

- `docs/DATAPLANE_APP_PREFLIGHT.ko.md`
- `fixtures/dataplane-app-baseline-policy.sample.yaml`
- `scripts/run-dataplane-preflight.sh`

완료 기준:

- app smoke failure 전에 network/environment failure를 먼저 분리 가능
- app repo가 baseline 내부 구현을 몰라도 실행 가능
- bori/operator로 넘길 contract가 명확함

## Sprint N7 - bori/operator 연동 기반

기간: 2주

목표:

향후 bori가 설치/운영 operator 역할을 맡을 수 있도록 CRD/API contract를 준비한다.

작업 항목:

- `NetworkBaselineRun` CRD 초안 작성
- `NetworkBaselinePolicy` CRD 초안 작성
- status condition 구조 정의
- artifact reference 구조 정의
- bori가 baseline 실행을 trigger하는 흐름 정의
- baseline result를 dataplane app rollout gate로 사용하는 흐름 정의

예상 산출물:

- `docs/BORI_OPERATOR_INTEGRATION_CONTRACT.ko.md`
- `deploy/crd/networkbaselinerun.yaml`
- `deploy/crd/networkbaselinepolicy.yaml`
- `fixtures/networkbaselinerun.sample.yaml`

완료 기준:

- bori가 어떤 CR을 만들고 어떤 status를 읽어야 하는지 명확함
- CLI/script 기반 실행 결과와 CRD status가 같은 schema를 공유함
- app rollout gate로 사용할 최소 condition이 정의됨

권장 condition:

```text
CollectionComplete
EvaluationComplete
BaselinePassed
BaselineWarned
BaselineFailed
Skipped
```

## Sprint N8 - 운영 제품 수준 안정화

기간: 2-4주

목표:

운영팀이 반복 사용해도 흔들리지 않는 제품 수준으로 만든다.

작업 항목:

- baseline history 저장
- cluster별 profile 관리
- Prometheus metric export
- Grafana dashboard 초안
- alert rule 초안
- release/tag 정책
- e2e test 환경
- 문서/Runbook 정리
- 보안/권한 최소화 검토

예상 산출물:

- `docs/OPERATIONS_RELEASE_CHECKLIST.ko.md`
- `docs/PROMETHEUS_GRAFANA_INTEGRATION.ko.md`
- `deploy/rbac/`
- `deploy/monitoring/`

완료 기준:

- 정기 실행과 수동 실행 모두 가능
- 결과가 시계열/리포트 양쪽으로 남음
- 운영팀이 실패를 재현하고 triage할 수 있음
- release마다 regression test를 통과함

## 우선순위

높음:

- same-node/cross-node
- DNS/Service discovery
- provider detection snapshot
- 큰 이미지 pull
- 대용량 데이터 경로
- fan-out churn
- report/gate UX

중간:

- MTU smoke
- NetworkPolicy allow/deny
- registry 세부 지표
- Prometheus/Grafana

낮음:

- mesh baseline
- gateway baseline
- full operator implementation

Mesh와 gateway는 중요하지만, 현재 유전체 dataplane app preflight 기준으로는
CNI, DNS, registry, storage, fan-out이 먼저다.

## 다음 작업자가 바로 시작할 위치

현재 기준 다음 작업은 Sprint N1이다.

추천 첫 작업:

1. 실제 클러스터에서 `./scripts/run-network-baseline-matrix.sh` 실행
2. single-node 환경에서 `cross-node-service-tcp`가 `skipped`로 기록되는지 확인
3. multi-node 환경에서 `same-node-service-tcp`, `cross-node-service-tcp` 배치가 의도대로 잡히는지 확인
4. 실제 VM에서 provider/object snapshot 실행 검증
5. 감지된 provider 기준 optional snapshot 우선순위 결정

작업 시작 전 확인:

```bash
cd /opt/go/src/github.com/HeaInSeo/network-baseline
git status -sb
make validate
```

작업 후 확인:

```bash
make validate
./scripts/run-network-baseline-matrix.sh
git status -sb
```

## 의사결정 기록

- 이 프로젝트는 전체 네트워크 장애 진단 도구가 아니다.
- 1차 책임은 Kubernetes dataplane app을 위한 network/environment preflight다.
- iperf3는 첫 측정 도구로 사용하되, 운영 수준에서는 DNS, CNI, registry,
  storage, fan-out까지 포함해야 한다.
- bori/operator 연동은 최종 목표지만, 지금은 CLI/script 기준선과 result schema를
  먼저 안정화한다.
- 유전체 분석 특성상 큰 이미지와 대용량 데이터 경로는 네트워크 throughput만큼
  중요하다.

## 완료 정의

이 계획의 1차 완료는 다음 상태다.

- 유전체 dataplane app 실행 전에 baseline을 한 번에 실행할 수 있음
- 결과가 `pass/warn/fail/skipped`로 정리됨
- 실패 원인을 network, DNS, CNI, registry, storage, fan-out 중 최소 한 층으로
  분리 가능
- 결과 artifact가 JSON과 Markdown으로 남음
- app repo와 bori가 같은 result schema를 소비할 수 있음
