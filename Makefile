.PHONY: validate summary-smoke report-smoke kustomize checks-kustomize genomic-kustomize crd-kustomize

validate:
	bash -n scripts/run-network-baseline.sh scripts/run-network-baseline-matrix.sh scripts/run-network-baseline-fanout.sh scripts/run-network-health-checks.sh scripts/run-network-policy-checks.sh scripts/run-mtu-smoke-check.sh scripts/run-node-reachability-check.sh scripts/run-conntrack-snapshot.sh scripts/run-provider-detection.sh scripts/run-k8s-object-snapshot.sh scripts/run-k8sgpt-analysis.sh scripts/run-image-pull-baseline.sh scripts/run-registry-connectivity-baseline.sh scripts/run-remote-fetch-http-baseline.sh scripts/run-local-reuse-same-node-baseline.sh scripts/run-job-churn-gc-baseline.sh scripts/run-genomic-environment-baseline.sh
	python3 -m py_compile tools/summary/summarize-network-baseline.py
	python3 -m py_compile tools/report/render-network-baseline-report.py
	$(MAKE) summary-smoke
	$(MAKE) report-smoke
	$(MAKE) kustomize
	$(MAKE) checks-kustomize
	$(MAKE) genomic-kustomize
	$(MAKE) crd-kustomize

summary-smoke:
	python3 tools/summary/summarize-network-baseline.py \
	  --iperf-json fixtures/iperf3-tcp.sample.json \
	  --out /tmp/network-baseline-tcp.result.json \
	  --run-id local-summary-smoke \
	  --scenario fixture-tcp \
	  --protocol tcp \
	  --profile operational \
	  --thresholds policy/network-baseline-thresholds.yaml
	python3 tools/summary/summarize-network-baseline.py \
	  --iperf-json fixtures/iperf3-udp.sample.json \
	  --out /tmp/network-baseline-udp.result.json \
	  --run-id local-summary-smoke \
	  --scenario fixture-udp \
	  --protocol udp \
	  --profile operational \
	  --thresholds policy/network-baseline-thresholds.yaml

report-smoke:
	mkdir -p /tmp/network-baseline-report-smoke
	cp fixtures/matrix-summary.sample.json /tmp/network-baseline-report-smoke/matrix-summary.json
	python3 tools/report/render-network-baseline-report.py \
	  --run-dir /tmp/network-baseline-report-smoke \
	  --out /tmp/network-baseline-report-smoke/report.md

kustomize:
	kubectl kustomize deploy/iperf3 >/tmp/network-baseline-kustomize.yaml

checks-kustomize:
	kubectl kustomize deploy/checks >/tmp/network-baseline-checks-kustomize.yaml

genomic-kustomize:
	kubectl kustomize deploy/genomic >/tmp/network-baseline-genomic-kustomize.yaml

crd-kustomize:
	kubectl kustomize deploy/crd >/tmp/network-baseline-crd-kustomize.yaml
