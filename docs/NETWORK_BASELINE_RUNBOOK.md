# Network Baseline Runbook

Date: 2026-06-05

## Prerequisites

- `kubectl`
- `k8sgpt`
- namespace access
- permission to create Deployment, Service, Job, ConfigMap, and Pod
- image pull access for `networkstatic/iperf3`

## Basic Run

```bash
kubectl create namespace network-baseline
./scripts/run-network-baseline.sh
```

## Matrix Run

```bash
./scripts/run-network-baseline-matrix.sh
```

The matrix run applies Kubernetes resources and therefore must run K8sGPT CLI
diagnosis before producing the final summary:

```bash
./scripts/run-k8sgpt-analysis.sh
```

`run-network-baseline-matrix.sh` calls this automatically. For any manual
resource-apply or Kubernetes integration run outside the matrix script, run the
same command before reporting the result.

Default scope is the `network-baseline` namespace. Use cluster scope only when
the operator explicitly needs cluster-wide evidence:

```bash
K8SGPT_SCOPE=cluster ./scripts/run-k8sgpt-analysis.sh
```

## Cleanup

```bash
kubectl -n network-baseline delete job -l app.kubernetes.io/name=network-baseline --ignore-not-found
kubectl -n network-baseline delete deploy,svc -l app.kubernetes.io/name=network-baseline --ignore-not-found
```

## K8sGPT Artifacts

K8sGPT outputs are written with the run artifacts:

```text
k8sgpt-analysis.json
k8sgpt-analysis.txt
k8sgpt-analysis.stderr
k8sgpt-analysis.summary.json
```

## Common Failures

### Server Pod Not Ready

Check:

```bash
kubectl -n network-baseline get pods -o wide
kubectl -n network-baseline describe pod -l app.kubernetes.io/component=iperf3-server
```

Likely causes:

- image pull issue
- scheduling issue
- namespace quota

### Client Job Fails

Check:

```bash
kubectl -n network-baseline logs job/iperf3-client
kubectl -n network-baseline describe job/iperf3-client
```

Likely causes:

- service DNS issue
- NetworkPolicy
- server not listening
- CNI dataplane issue

### Low Throughput

Check:

- same-node versus cross-node difference
- service path versus direct Pod IP difference
- node CPU pressure
- CNI health
- MTU mismatch

### UDP Loss

Check:

- requested bandwidth too high
- cross-node packet loss
- NetworkPolicy/CNI behavior
- node pressure
