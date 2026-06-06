.PHONY: validate summary-smoke kustomize checks-kustomize crd-kustomize

validate:
	bash -n scripts/run-network-baseline.sh scripts/run-network-baseline-matrix.sh scripts/run-network-baseline-fanout.sh scripts/run-network-health-checks.sh scripts/run-network-policy-checks.sh scripts/run-mtu-smoke-check.sh scripts/run-node-reachability-check.sh scripts/run-conntrack-snapshot.sh
	python3 -m py_compile tools/summary/summarize-network-baseline.py
	$(MAKE) summary-smoke
	$(MAKE) kustomize
	$(MAKE) checks-kustomize
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

kustomize:
	kubectl kustomize deploy/iperf3 >/tmp/network-baseline-kustomize.yaml

checks-kustomize:
	kubectl kustomize deploy/checks >/tmp/network-baseline-checks-kustomize.yaml

crd-kustomize:
	kubectl kustomize deploy/crd >/tmp/network-baseline-crd-kustomize.yaml
