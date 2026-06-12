# Network Baseline Reporting

작성일: 2026-06-06

## 목적

VM 기반 K8s 환경에서 `run-network-baseline-matrix.sh`를 실행한 뒤, 운영자와 bori
개발 agent가 결과를 빠르게 검토할 수 있도록 Markdown report를 생성한다.

## 실행

matrix 실행:

```bash
./scripts/run-network-baseline-matrix.sh
```

report 생성:

```bash
python3 tools/report/render-network-baseline-report.py \
  --run-dir artifacts/network-baseline/<run-id>
```

genomic environment summary를 명시적으로 렌더링:

```bash
python3 tools/report/render-network-baseline-report.py \
  --run-dir artifacts/network-baseline/<run-id> \
  --summary artifacts/network-baseline/<run-id>/genomic-environment-summary.json
```

생성 파일:

```text
artifacts/network-baseline/<run-id>/report.md
artifacts/network-baseline/<run-id>/gate-summary.json
```

## 리포트 구성

- run id
- overall status
- scenario별 status
- throughput 요약
- provider detection 요약
- Kubernetes object snapshot count
- triage 순서

`genomic-environment-summary.json` 입력일 때는 아래 항목을 별도 표로 보여준다.

- image pull primary/mirror 상태
- registry connectivity primary/mirror 상태
- remote fetch bytes/digest/cleanup 상태
- local reuse same-node/digest/cleanup 상태
- Job churn/GC 상태
- K8sGPT finding 수
- bori gate decision: `pass`, `manual-review`, `block`

## Gate Summary JSON

`run-genomic-environment-baseline.sh`는 `genomic-environment-summary.json`과
`report.md`에 더해 `gate-summary.json`을 생성한다. bori나 다른 운영 agent는
Markdown을 파싱하지 않고 이 JSON만 읽으면 된다.

핵심 필드:

- `decision`: `pass`, `manual-review`, `block`
- `status`: 원본 summary의 전체 상태
- `requiredInputsMissing`: 입력값 미비로 `skipped`된 scenario
- `blockingScenarios`: gate를 막아야 하는 scenario
- `manualReviewScenarios`: 수동 검토가 필요한 scenario
- `scenarioResults[].evidence`: 관련 artifact path

판정 정책:

- `fail`이 하나라도 있으면 `block`
- `warn` 또는 `skipped`가 하나라도 있으면 `manual-review`
- 모든 필수 scenario가 `pass`이면 `pass`

따라서 Harbor/GHCR image ref 또는 artifact URL이 없어서 image pull, registry,
remote fetch가 `skipped`인 실행은 운영상 `pass`가 아니라 `manual-review`다.

## 운영 해석 순서

1. `fail` scenario를 먼저 본다.
2. DNS/Service discovery가 실패하면 throughput 결과보다 DNS/Service를 먼저 본다.
3. NetworkPolicy가 실패하면 selector와 CNI policy enforcement를 본다.
4. MTU 또는 node reachability가 실패하면 VM network, CNI overlay, firewall을 본다.
5. conntrack warning/fail이면 fan-out과 short-lived connection churn을 본다.
6. core health가 통과했는데 throughput만 낮으면 datapath, placement, provider-specific signal을 본다.

## bori 연결

bori는 `matrix-summary.json`을 machine-readable gate input으로 사용하고,
`report.md`를 사람 검토용 artifact로 보존하는 방향이 적합하다.
