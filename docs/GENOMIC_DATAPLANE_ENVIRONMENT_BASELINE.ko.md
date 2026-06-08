# Genomic Dataplane Environment Baseline

작성일: 2026-06-06

## 목적

이 문서는 `network-baseline`의 N4 범위를 JUMI, artifact-handoff(AH),
node-artifact-runtime(nan)의 실제 책임 경계에 맞춰 정의한다.

목표는 단순 네트워크 throughput을 넘어, Kubernetes 데이터 플레인에서
유전체 분석 app을 실행하기 전에 운영자가 확인해야 하는 환경 기준선을
만드는 것이다.

## JUMI, AH, nan 관계

세 프로젝트의 책임은 아래처럼 분리된다.

```text
JUMI
  - DAG 실행 주체
  - K8s Job/Pod 생성 및 관찰
  - AH ResolveHandoff 호출
  - AH 결과를 PodSpec/env/runtime context에 반영
  - nan manifest 회수
  - AH RegisterArtifact 호출

AH
  - artifact registry/resolver
  - artifact identity, locality, placement intent 판단
  - MaterializationPlan 반환
  - backend-neutral handoff semantics 소유
  - K8s Job/Pod 직접 생성하지 않음

nan
  - DAG node 컨테이너 내부 runtime shim
  - user command 실행
  - output inspect
  - digest/size 계산
  - manifest 작성
  - AH/K8s API 직접 호출하지 않음
```

따라서 `network-baseline`은 JUMI/AH/nan을 직접 대체하지 않는다.
대신 세 프로젝트가 실제 DAG를 실행하기 전에, 클러스터 환경이 최소한의
운영 기준을 만족하는지 검증하는 preflight evidence를 만든다.

## 중요한 비전제

N4 baseline은 다음을 전제로 하지 않는다.

- PVC 사용
- 특정 CNI 사용
- 특정 service mesh 사용
- 특정 object storage 사용
- Dragonfly 같은 특정 transfer backend 사용
- AH가 K8s Job/Pod를 만든다는 가정
- nan이 AH 또는 K8s API를 직접 호출한다는 가정

PVC 기반 shared storage benchmark는 이 프로젝트의 현재 범위가 아니다.
대용량 데이터 경로는 `remote_fetch`, `local_reuse`, image pull, registry
접근성 관점에서 먼저 측정한다.

## N4 측정 축

### 1. Image Pull Baseline

유전체 분석 app은 크기가 큰 컨테이너 이미지를 사용하는 경우가 많다.
JUMI service image, AH service image, nan/runtime/tool image는 서로 다른
역할을 갖기 때문에 측정 결과도 분리되어야 한다.

Registry 기준:

- Harbor를 운영 정본 registry로 본다.
- GHCR은 외부 동기화 대상 또는 mirror registry로 본다.
- baseline은 Harbor pull을 primary gate로 평가한다.
- GHCR은 Harbor와의 동기화 여부, tag/digest 일치, mirror fallback 가능성을
  검증하는 secondary evidence로 기록한다.
- Harbor 실패와 GHCR 실패는 같은 의미가 아니다. Harbor 실패는 운영 정본
  registry 접근성 문제이고, GHCR 실패는 sync/mirror 경로 문제로 분리한다.

측정 항목:

- registry DNS resolution
- registry TCP/TLS 연결 가능 여부
- Harbor image pull 성공/실패
- GHCR mirror image pull 성공/실패
- Harbor/GHCR tag digest 일치 여부
- image pull 대기 시간
- image pull 실패 원인
- image cache hit/miss 추정 evidence
- Pod start latency
- node별 편차

현재 구현:

```bash
PRIMARY_IMAGE=harbor.example/heainseo/jumi@sha256:... \
MIRROR_IMAGE=ghcr.io/heainseo/jumi@sha256:... \
  ./scripts/run-image-pull-baseline.sh
```

`PRIMARY_IMAGE`는 Harbor 정본 이미지를 의미한다. `MIRROR_IMAGE`는 GHCR 동기화
이미지를 의미한다. 둘 다 digest-qualified reference를 권장한다.

Probe 방식:

- Kubernetes Pod를 만든다.
- 대상 image를 container image로 지정한다.
- 존재하지 않는 command를 실행해도 image pull 자체가 성공하면 `imageID`가 기록된다.
- `imageID`에서 digest를 추출해 Harbor/GHCR digest 일치 여부를 기록한다.
- probe Pod는 기본적으로 evidence 수집 후 삭제한다.

운영 판단:

- 네트워크 throughput은 정상인데 image pull이 느린지 분리한다.
- 특정 node에서만 registry 접근이 실패하는지 확인한다.
- 큰 image rollout 전에 허용 가능한 pull 시간을 정한다.
- Harbor 기준 digest와 GHCR mirror digest가 어긋나는지 확인한다.

### 2. Remote Fetch HTTP Baseline

AH의 `MaterializationPlan.mode=remote_fetch`는 특정 전송 기술명이 아니다.
현재 node에서 artifact를 사용할 수 있게 준비하라는 의미다.

초기 baseline은 가장 단순한 HTTP artifact source를 사용한다. 목적은
HTTP를 최종 backend로 고정하는 것이 아니라, remote_fetch 계약이 실제
bytes 이동, digest 검증, 실패 attribution으로 이어질 수 있는지 검증하는
것이다.

측정 항목:

- artifact source Service DNS resolution
- HTTP fetch 성공/실패
- size별 fetch latency
- digest verification 결과
- partial download cleanup 여부
- 실패 시 DNS/Service/HTTP/digest 구분

운영 판단:

- data path 문제가 app logic 실패처럼 보이지 않게 분리한다.
- 작은 파일 happy path 이후 `10MB`, `100MB`, `1GiB+`로 확장한다.
- 외부 transport backend 도입 전 계약 자체를 먼저 검증한다.

### 3. Node-local Local Reuse Baseline

`local_reuse`는 같은 node에 이미 artifact가 있는 경우 이를 재사용하는
경로다. PVC가 아니라 node-local path 또는 node-local CAS 같은 개념으로
검증한다.

측정 항목:

- producer/consumer same-node placement 가능 여부
- node-local artifact path 가용성
- expected digest 일치 여부
- consumer가 node-local artifact를 읽을 수 있는지
- run 종료 후 cleanup evidence
- locality miss 발생 시 fallback 기록

운영 판단:

- same-node reuse가 실제 배치와 연결되는지 확인한다.
- local path 권한, cleanup, stale artifact 위험을 조기에 드러낸다.
- 이후 AH/JUMI placement policy와 연결할 수 있는 evidence를 남긴다.

### 4. Job Fan-out And Churn Baseline

유전체 분석 DAG는 여러 node와 sample을 병렬 실행할 수 있다. 이때 단일
throughput보다 중요한 것은 Job/Pod churn이 DNS, CNI, API server, registry,
cleanup에 미치는 영향이다.

측정 항목:

- fan-out job count별 성공률
- Pod scheduling latency
- Pod start latency
- Job completion latency
- TTL/GC 상태
- failed/evicted/pending Pod 수
- DNS check와 provider snapshot 동시 evidence

운영 판단:

- 많은 Job 생성 시 fast-fail 방식이 운영적으로 감당 가능한지 확인한다.
- cleanup이 누락되어 다음 run을 오염시키지 않는지 확인한다.
- bori/operator gate에서 반복 가능한 warn/fail 기준을 만들 수 있다.

## 결과 구조

N4 결과 JSON은 아래 section을 가져야 한다.

```json
{
  "imagePull": {
    "status": "pass|warn|fail|skipped",
    "primaryRegistry": "harbor",
    "mirrorRegistry": "ghcr",
    "image": "...",
    "primaryDigest": "...",
    "mirrorDigest": "...",
    "digestMatched": true,
    "pullSeconds": 0,
    "podStartSeconds": 0,
    "evidence": []
  },
  "remoteFetch": {
    "status": "pass|warn|fail|skipped",
    "sourceUri": "...",
    "sizeBytes": 0,
    "fetchSeconds": 0,
    "digestVerified": true,
    "failureLayer": "dns|service|http|digest|cleanup|unknown"
  },
  "localReuse": {
    "status": "pass|warn|fail|skipped",
    "placement": "same-node|required-node|missed|unknown",
    "nodeName": "...",
    "digestVerified": true,
    "cleanupObserved": true
  },
  "fanout": {
    "status": "pass|warn|fail|skipped",
    "jobs": 0,
    "succeeded": 0,
    "failed": 0,
    "p95CompletionSeconds": 0
  },
  "gc": {
    "status": "pass|warn|fail|skipped",
    "jobsRemaining": 0,
    "podsRemaining": 0,
    "ttlSecondsAfterFinished": 0
  }
}
```

## bori 연동 관점

향후 bori가 설치 오퍼레이터 또는 운영 게이트 역할을 맡으면,
`network-baseline`의 N4 결과는 app-specific DAG smoke test 이전의
환경 evidence로 쓰는 것이 적합하다.

권장 순서:

```text
1. provider-neutral network baseline
2. DNS/NetworkPolicy/MTU/node reachability baseline
3. image pull / registry baseline
4. remote_fetch HTTP baseline
5. node-local local_reuse baseline
6. fan-out/churn/GC baseline
7. JUMI/AH/nan app-specific DAG smoke
```

이 순서를 따르면 운영자는 실패가 app logic인지, runtime contract인지,
registry/data path인지, Kubernetes network/provider 문제인지 더 빨리
분리할 수 있다.

## N4 구현 순서

권장 구현 순서:

1. `image-pull-baseline` — 구현됨: `scripts/run-image-pull-baseline.sh`
2. `registry-connectivity-baseline`
3. `remote-fetch-http-baseline`
4. `local-reuse-same-node-baseline`
5. `fanout-churn-gc-baseline`

현재 VM/K8s 환경은 아직 테스트 중이므로, 구현은 manifest/script/schema
검증까지 먼저 진행하고 실제 원격 클러스터 실행은 VM 사용 가능 시점에
진행한다.
