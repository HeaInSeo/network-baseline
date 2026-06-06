# Provider-neutral Observability Baseline

작성일: 2026-06-06

## 목적

`network-baseline`은 특정 CNI, service mesh, gateway 제품을 검증하는 도구가 아니다.
목표는 Kubernetes dataplane app이 제품 적용 환경에서 실행 가능한지 판단하는
공통 preflight/baseline을 제공하는 것이다.

제품이 적용되는 현장의 CNI/mesh/gateway는 우리가 선택할 수 없다. 따라서 core
baseline은 provider-neutral이어야 한다.

## 원칙

필수 baseline:

- Kubernetes 공통 API와 일반 Pod/Service/Job/DaemonSet으로 동작한다.
- CNI나 mesh 제품이 무엇인지 몰라도 실행 가능해야 한다.
- provider가 없다는 이유로 실패하지 않는다.

선택 provider baseline:

- Cilium, Istio, Linkerd, Calico 같은 provider가 감지되면 추가 artifact를 수집한다.
- 감지되지 않으면 `skipped`로 기록한다.
- provider 존재 환경에서 수집 실패는 `warn` 또는 `fail`로 판단한다.

## 계층

```text
Core Kubernetes baseline
  -> dns-service-discovery
  -> networkpolicy-allow-deny
  -> mtu-smoke
  -> node-to-node-reachability
  -> conntrack-snapshot
  -> service/direct/fanout iperf3 baseline

Provider detection
  -> CNI 감지
  -> mesh 감지
  -> gateway 감지

Core object snapshot
  -> nodes
  -> pods
  -> services
  -> endpoints/endpointslices
  -> networkpolicies
  -> events
  -> kube-system pods

Optional provider snapshots
  -> cilium
  -> istio
  -> linkerd
  -> calico
  -> gateway api / ingress controller
```

## Provider 감지 기준

감지는 best-effort로 수행한다.

### Cilium

가능한 신호:

- `kube-system` 또는 `cilium` namespace의 `cilium` DaemonSet
- `cilium.io` CRD
- `hubble` Deployment/Service

수집 후보:

- Cilium Pod 상태
- Cilium CRD 존재 여부
- Hubble relay/UI 존재 여부
- Hubble flow 수집 가능 여부

### Istio

가능한 신호:

- `istio-system` namespace
- `istiod` Deployment
- `sidecar.istio.io` annotation
- Envoy sidecar container

수집 후보:

- control plane Pod 상태
- namespace injection label
- 대상 namespace의 sidecar 주입 여부
- proxy readiness

### Linkerd

가능한 신호:

- `linkerd` namespace
- `linkerd-proxy` sidecar
- Linkerd control plane Deployment

수집 후보:

- control plane Pod 상태
- 대상 namespace의 proxy 주입 여부
- proxy readiness

### Calico

가능한 신호:

- `calico-system` namespace
- `calico-node` DaemonSet
- `crd.projectcalico.org` CRD

수집 후보:

- calico-node 상태
- policy CRD 존재 여부
- Felix 관련 Pod 상태

## Result Contract

provider snapshot 결과는 기존 health schema를 사용한다.

```json
{
  "schemaVersion": "network-baseline.health.v1",
  "scenario": {
    "name": "provider-detection",
    "type": "provider-detection"
  },
  "providers": [
    {
      "name": "cilium",
      "kind": "cni",
      "detected": true,
      "status": "pass",
      "reasons": []
    },
    {
      "name": "istio",
      "kind": "mesh",
      "detected": false,
      "status": "skipped",
      "reasons": ["provider not detected"]
    }
  ],
  "status": "pass"
}
```

## Status 규칙

- provider 미감지: `skipped`
- provider 감지 + 기본 리소스 정상: `pass`
- provider 감지 + 일부 수집 실패: `warn`
- provider 감지 + 핵심 control plane 비정상: `fail`

단, provider snapshot의 `fail`이 항상 dataplane app rollout block을 의미하지는 않는다.
bori나 운영 policy가 해당 provider 신호를 blocking으로 볼지 결정한다.

## bori 연결

bori는 provider 종류를 미리 가정하지 않는다.

권장 흐름:

```text
bori
  -> network-baseline matrix 실행
  -> core baseline result 확인
  -> provider-detection result 확인
  -> 감지된 provider artifact를 rollout evidence로 보존
```

bori gate 기본값:

- core baseline fail: blocking
- provider 미감지: non-blocking
- provider snapshot warn: policy에 따라 manual review
- provider snapshot fail: provider가 대상 환경의 필수 provider이면 blocking

## 다음 구현 순서

1. `provider-detection` snapshot 구현 완료
2. `k8s-object-snapshot` 구현 완료
3. Cilium optional snapshot 구현
4. Istio optional snapshot 구현
5. bori policy에서 optional provider result의 blocking 여부를 표현

## 실행

```bash
./scripts/run-provider-detection.sh
./scripts/run-k8s-object-snapshot.sh
```

matrix 실행에도 포함된다.

```bash
./scripts/run-network-baseline-matrix.sh
```

결과 파일:

```text
artifacts/network-baseline/<run-id>/provider-detection.result.json
artifacts/network-baseline/<run-id>/provider-detection.namespaces.txt
artifacts/network-baseline/<run-id>/provider-detection.crds.txt
artifacts/network-baseline/<run-id>/provider-detection.pods_all.txt
artifacts/network-baseline/<run-id>/k8s-object-snapshot.result.json
artifacts/network-baseline/<run-id>/k8s-object-snapshot.nodes.json
artifacts/network-baseline/<run-id>/k8s-object-snapshot.pods_all.json
```
