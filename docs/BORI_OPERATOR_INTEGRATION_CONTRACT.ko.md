# bori Operator 통합 계약 초안

작성일: 2026-06-06

## 목적

이 문서는 `network-baseline`이 향후 bori 운영 operator와 통합될 때 사용할
최소 계약을 정의한다.

현재 `network-baseline`은 독립 실행 가능한 preflight/baseline 도구다. bori는
이 도구의 내부 구현을 직접 알아야 하는 것이 아니라, 다음 계약을 통해 실행과
판정을 연결한다.

- scenario 이름
- threshold policy 이름
- result schema
- artifact 위치
- status condition
- rollout gate 판단 기준

## 역할 분리

`network-baseline` 책임:

- 네트워크/환경 baseline scenario 정의
- Kubernetes Job/Pod 실행 방식 제공
- threshold policy 제공
- result JSON 생성
- `pass`, `warn`, `fail`, `skipped` 판정
- artifact/report 생성

`bori` 책임:

- 언제 baseline을 실행할지 결정
- 어떤 cluster/app/profile에 baseline을 적용할지 결정
- `NetworkBaselineRun` 생성 또는 동등한 실행 요청 생성
- result/status를 읽고 rollout gate로 사용
- dataplane app install/upgrade/rollback 흐름과 연결

## 권장 리소스

초기 계약은 두 리소스로 충분하다.

```text
NetworkBaselinePolicy
  -> 어떤 profile과 threshold를 사용할지 정의

NetworkBaselineRun
  -> 특정 app/cluster/context에서 baseline 실행 요청과 결과를 표현
```

CRD 초안은 다음 위치에 둔다.

```text
deploy/crd/networkbaselinepolicy.yaml
deploy/crd/networkbaselinerun.yaml
```

샘플 리소스는 다음 위치에 둔다.

```text
fixtures/networkbaselinepolicy.sample.yaml
fixtures/networkbaselinerun.sample.yaml
```

## NetworkBaselinePolicy

`NetworkBaselinePolicy`는 운영 profile과 scenario별 threshold를 정의한다.

예상 사용:

```yaml
apiVersion: baseline.heainseo.dev/v1alpha1
kind: NetworkBaselinePolicy
metadata:
  name: operational
spec:
  profile: operational
  thresholdsRef:
    kind: ConfigMap
    name: network-baseline-thresholds
  defaultScenarios:
    - service-tcp
    - service-udp
    - pod-direct-tcp
    - cross-node-tcp
```

bori는 app rollout 전에 해당 app에 연결된 policy를 선택한다.

## NetworkBaselineRun

`NetworkBaselineRun`은 한 번의 baseline 실행 요청과 결과를 표현한다.

예상 사용:

```yaml
apiVersion: baseline.heainseo.dev/v1alpha1
kind: NetworkBaselineRun
metadata:
  name: jumi-preflight
spec:
  policyRef:
    name: operational
  target:
    app: jumi
    namespace: jumi-system
  scenarios:
    - service-tcp
    - service-udp
    - cross-node-tcp
  artifact:
    mode: local
```

## Status Contract

bori가 읽어야 하는 최소 status는 다음이다.

```yaml
status:
  phase: Completed
  result: pass
  runId: network-baseline-20260606T000000Z
  artifactRef:
    path: artifacts/network-baseline/network-baseline-20260606T000000Z
  conditions:
    - type: CollectionComplete
      status: "True"
    - type: EvaluationComplete
      status: "True"
    - type: BaselinePassed
      status: "True"
```

현재 shell 기반 실행에서는 위 status를 직접 CRD에 쓰지 않는다. 대신 bori가
읽을 수 있는 machine-readable artifact로 `gate-summary.json`을 생성한다.

```json
{
  "schemaVersion": "network-baseline.gateSummary.v1",
  "runId": "genomic-environment-20260612T000000Z",
  "status": "warn",
  "decision": "manual-review",
  "artifactDirectory": "artifacts/network-baseline/genomic-environment-20260612T000000Z",
  "summaryPath": "artifacts/network-baseline/genomic-environment-20260612T000000Z/genomic-environment-summary.json",
  "reportPath": "artifacts/network-baseline/genomic-environment-20260612T000000Z/report.md",
  "blockingScenarios": [],
  "manualReviewScenarios": ["image-pull-baseline"],
  "requiredInputsMissing": ["image-pull-baseline"],
  "scenarioResults": []
}
```

bori는 초기 통합에서 CRD status 대신 `gate-summary.json.decision`을 읽어도 된다.
향후 operator/controller 단계에서는 같은 값을 `NetworkBaselineRun.status.result`
및 condition으로 투영하면 된다.

## Phase 값

권장 phase:

- `Pending`: 실행 요청이 생성됨
- `Running`: baseline Job 또는 수집 작업이 진행 중
- `Evaluating`: 수집 완료 후 threshold 판정 중
- `Completed`: 평가 완료
- `Failed`: 실행 또는 평가 중 복구 불가능한 실패
- `Skipped`: 환경 조건상 의도적으로 생략

## Result 값

권장 result:

- `pass`: baseline 통과
- `warn`: 운영 확인 필요
- `fail`: gate 실패
- `skipped`: 의도적 생략

`warn`은 기본적으로 rollout 자동 중단 조건은 아니지만, policy에 따라 bori가
수동 승인 대기로 바꿀 수 있다.

## Condition 값

권장 condition:

- `CollectionComplete`
- `EvaluationComplete`
- `BaselinePassed`
- `BaselineWarned`
- `BaselineFailed`
- `Skipped`

Condition은 Kubernetes 표준 형태를 따른다.

```yaml
type: BaselinePassed
status: "True"
reason: ThresholdsSatisfied
message: All requested scenarios passed operational thresholds.
lastTransitionTime: "2026-06-06T00:00:00Z"
```

## Rollout Gate 판단

권장 기본 판단:

```text
decision=pass
  -> rollout 진행 가능

decision=manual-review
  -> policy에 따라 수동 승인, 제한 진행, 또는 중단

decision=block
  -> rollout 중단
```

`skipped`는 운영상 성공이 아니다. Harbor/GHCR image ref, registry URL, artifact
URL 같은 필수 입력이 없어서 생략된 scenario가 있으면 기본 decision은
`manual-review`다.

bori가 app upgrade를 처리할 때 권장 흐름:

```text
1. NetworkBaselineRun 생성
2. baseline 실행 완료 대기
3. status.result 확인
4. artifactRef 저장
5. pass면 dataplane app rollout 진행
6. warn이면 policy에 따라 수동 승인 또는 제한 진행
7. fail이면 rollout 중단
```

## Artifact Contract

`artifactRef.path` 아래에는 최소한 다음 파일이 있어야 한다.

```text
genomic-environment-summary.json
gate-summary.json
report.md
<scenario>.result.json
```

운영 수준으로 확장되면 다음 artifact를 추가한다.

```text
cluster-snapshot.json
node-snapshot.json
cilium-status.json
hubble-flows.json
provider-detection.result.json
image-pull-baseline.result.json
registry-connectivity-baseline.result.json
remote-fetch-http-baseline.result.json
local-reuse-same-node-baseline.result.json
job-churn-gc-baseline.result.json
k8sgpt-analysis.summary.json
```

Provider artifact는 optional이다. provider가 없다는 이유로 baseline이 실패해서는
안 된다. provider가 감지되면 bori는 해당 artifact를 rollout evidence로 보존하고,
policy에 따라 blocking 여부를 결정한다.

## App Target Contract

`spec.target`은 baseline이 어떤 dataplane app과 연결되는지 표현한다.

```yaml
target:
  app: jumi
  namespace: jumi-system
  version: v0.1.1
  rollout: pre-upgrade
```

초기에는 `app`과 `namespace`만 필수로 둔다. `version`, `rollout`은 향후 bori
rollout manager와 연결할 때 사용한다.

## 현재 구현과의 관계

현재 `network-baseline v0.1.0`은 아직 CRD controller를 제공하지 않는다.

현재 가능한 것:

- shell script로 baseline 실행
- result JSON 생성
- genomic environment summary 생성
- gate summary 생성
- Markdown report 생성
- threshold profile 사용

향후 bori 통합 시 필요한 것:

- CRD 적용
- controller 또는 bori adapter가 script/CLI 실행
- status condition 업데이트
- artifactRef 기록

즉, 현재 CRD는 실행 가능한 operator 구현이 아니라 **API contract 초안**이다.

## 다음 구현 순서

권장 순서:

1. `NetworkBaselineRun`/`Policy` CRD 초안 유지
2. result schema와 condition 이름 고정
3. CLI/script가 `NetworkBaselineRun` 샘플과 같은 result를 만들도록 정렬
4. bori 쪽에서 CRD를 읽는 adapter 또는 controller 초안 작성
5. rollout gate에 `status.result` 연결
