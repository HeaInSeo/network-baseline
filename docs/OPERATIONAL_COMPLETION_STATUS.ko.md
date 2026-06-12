# Operational Completion Status

작성일: 2026-06-12

## 범위

이 문서는 N6 app preflight 연동을 제외하고 `network-baseline`의 현재 완료 상태와
남은 외부 입력 조건을 정리한다.

## 완료된 항목

N1-N3:

- iperf3 기반 TCP/UDP baseline
- DNS/Service discovery
- NetworkPolicy allow/deny
- MTU smoke
- node-to-node reachability
- conntrack snapshot
- provider-neutral provider detection
- Kubernetes object snapshot
- K8sGPT CLI 분석 의무화
- kube-linter GitHub Action

N4:

- image pull baseline
- registry connectivity baseline
- remote fetch HTTP baseline
- node-local same-node local reuse baseline
- Job churn/GC baseline
- genomic environment wrapper

N5:

- `genomic-environment-summary.json`
- `gate-summary.json`
- `report.md`
- bori/operator가 읽을 수 있는 gate decision
- `pass`, `manual-review`, `block` 정책

## Gate Decision 정책

기본 정책:

- `pass`: 모든 필수 scenario가 통과
- `manual-review`: 하나 이상의 `warn` 또는 `skipped` 존재
- `block`: 하나 이상의 `fail` 존재

중요한 점:

- `skipped`는 성공이 아니다.
- Harbor/GHCR image ref가 없어서 image pull이 생략되면 `manual-review`다.
- artifact URL이 없어서 remote fetch가 생략되면 `manual-review`다.
- 실제 운영 rollout gate는 `gate-summary.json.decision`을 기준으로 판단한다.

## 외부 입력이 필요한 항목

아래 항목은 코드/문서/실행 구조는 준비됐지만, 실제 운영값 없이는 `pass`로
닫을 수 없다.

- Harbor 정본 image ref
- GHCR mirror image ref
- Harbor/GHCR digest 일치 기준
- 실제 artifact URL
- artifact size별 목표값: 10MB, 100MB, 1GiB+

입력값이 준비되면 다음처럼 실행한다.

```bash
PRIMARY_IMAGE=harbor.example/heainseo/jumi@sha256:... \
MIRROR_IMAGE=ghcr.io/heainseo/jumi@sha256:... \
PRIMARY_REGISTRY_URL=https://harbor.example/v2/ \
MIRROR_REGISTRY_URL=https://ghcr.io/v2/ \
FETCH_URL=https://artifact-source.example/data.bin \
EXPECTED_SHA256=... \
CHURN_JOBS=20 \
  ./scripts/run-genomic-environment-baseline.sh
```

## N6 제외 후 남는 상태

N6는 JUMI/AH/nan/tori 같은 dataplane app smoke 앞단에 이 baseline을 붙이는
작업이다. 이 문서의 완료 기준에는 포함하지 않는다.

N6를 제외하면 현재 남은 것은 코드 작업이 아니라 운영 입력값을 넣은 재실행과
증거 확보다. 입력값이 없으면 올바른 최종 상태는 `manual-review`다.
