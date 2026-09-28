# Telemetry Specification (T6.1)

> **Inherits:** [Common Experiment Specification](common-experiment-setup.md).
> **Status:** Draft — pending full T6.2 verification (two consecutive clean runs per scenario,
> across all three scenarios).
> Operator-facing metric summaries live in each scenario's runbook; this document is the single
> place that defines *every* collected metric's source, meaning, unit, labels, granularity, and
> intended interpretation, per T6.1's deliverable text.

---

## 1. Scope and sources

The benchmark's telemetry is drawn from three component families, each already deployed and
scraped by the workflow (no new instrumentation required):

| Source | What it exposes | How it's scraped |
|--------|------------------|-------------------|
| **vLLM** (`/metrics`, `vllm:` prefix) | Inference execution: request/queue state, latency histograms, token throughput, KV-cache pressure | Workflow-applied `PodMonitor` ([`workflow/templates/vllm-podmonitor.yaml.tmpl`](../../workflow/templates/vllm-podmonitor.yaml.tmpl)), leader pods only |
| **NVIDIA DCGM exporter** (`DCGM_*`) | Infra utilisation: per-GPU compute, memory, power | GPU-operator's own `ServiceMonitor` ([`workflow/templates/gpu-operator-values.yaml`](../../workflow/templates/gpu-operator-values.yaml)) |
| **llm-d router / endpoint-picker (EPP)** (`inference_pool_*`, `inference_objective_*`) | Routing / backend discovery: which backends the router considers ready and is actually routing to | The llm-d router subchart's own `ServiceMonitor` (not authored by this repo) |

All three are scraped by the **KOF collectors** into **VictoriaMetrics**, queried by the collect
phase's range-query API (`vm_query_range_json`) and, for live readiness gates elsewhere in the
workflow, its instant-query API (`vm_query_json`/`vm_query_scalar`) —
[`workflow/lib/common.sh`](../../workflow/lib/common.sh).

### 1.1 Selection philosophy

T6.2 verifies whichever metrics this spec actually selects (component-agnostic — see the common
spec's own note on this). Each source exposes many more series than are listed here; the selection
criterion throughout is **does this metric help understand or depict one of the three scenarios'
own stories**, not exhaustive coverage of every exporter:

- **S1 (single-node)** needs a baseline: one GPU loaded, one pod's request/latency/throughput
  behaviour, nothing to compare within the run itself.
- **S2 (replicated)** is fundamentally a **distribution** story: does load actually spread evenly
  across the two replicas? This is why S2 gets two independent, cross-checking distribution views
  below — one from vLLM's own per-pod counters, one from the router/EPP's per-pod view — rather
  than relying on a single source.
- **S3 (sharded)** is a **placement** story (already hard-gated structurally, see the common spec
  §7.1 pod-placement check) plus a **is-this-actually-split** story, where DCGM alone is
  insufficient (see the Infra utilisation table below) and `system_fingerprint` plus placement
  jointly stand in as the real proof.

llm-d in particular ships many more metrics than are listed here (autoscaling signals, flow
control, prefill/decode-disaggregation coordination) — irrelevant, since this benchmark uses none
of those features.

---

## 2. Metric catalogue

Granularity is the scrape `interval` set on the relevant `PodMonitor`/`ServiceMonitor`. "Feeds"
names the acceptance criteria (common spec §7, or scenario-specific `A1.x`/`A2.x`/`A3.x`) and/or
the T6.4 dashboard panel each series supports.

Every series below is collected as a **time series over the run's serving window**: the collect
phase range-queries from the start of the `execute` phase (functional probe + aiperf load) through
collect time, at `VM_RANGE_STEP` (default 15s), storing the full `[timestamp, value]` array per
series in `metrics/*.json`. This is what lets the collected data depict *how* a scenario behaved
(ramp-up, steady state), not just its value at one moment.

### Deployment status

| Metric | Source | Unit | Labels | Granularity | Meaning | Feeds |
|--------|--------|------|--------|-------------|---------|-------|
| Phase timings (`phases.tsv`) | Workflow itself (not scraped; written directly by each phase script) | s | phase name, timestamp | per-phase, on transition | Wall-clock time from phase start to completion | Common §7.1 (provisioning), indicative-timings tables in each scenario spec |

### Infra utilisation

| Metric | Source | Unit | Labels (observed) | Granularity | Meaning | Feeds |
|--------|--------|------|--------------------|-------------|---------|-------|
| `DCGM_FI_DEV_GPU_UTIL` | DCGM exporter | % | `Hostname`, `UUID`, `gpu`, `modelName`, `pci_bus_id` | 15s | SM (compute) utilisation of one GPU | Dashboard: infra panel |
| `DCGM_FI_DEV_FB_USED` | DCGM exporter | MiB | same as above | 15s | GPU frame-buffer (VRAM) reservation | A1.2, A2.3, A3.2 — confirms a GPU is loaded; **not** a proof of split ratio (see scenario-3 spec's A3.2 note: it tracks vLLM's configured `gpu_memory_utilization` reservation, not actual weight footprint) |
| `DCGM_FI_DEV_POWER_USAGE` | DCGM exporter | W | same as above | 15s | Power draw | Dashboard: infra panel (informational) |

### Inference execution

| Metric | Source | Unit | Labels (observed) | Granularity | Meaning | Feeds |
|--------|--------|------|--------------------|-------------|---------|-------|
| `vllm:num_requests_running` | vLLM | count | `instance` (pod IP:port), `model_name` | 15s | In-flight request count on one server | S1 baseline saturation; **S2 distribution view #1** — an even spread across pods' `instance` values is one of the two load-balancing proofs (see §1.1) |
| `vllm:time_to_first_token_seconds_count` / `_sum` | vLLM | count / seconds | `instance`, `model_name` | 15s | Histogram sample count and cumulative sum backing TTFT | `rate(_sum)/rate(_count)` gives **average TTFT over time**, queryable live — cross-checked against aiperf's own end-of-run TTFT percentile in `run-report.md` |
| `vllm:e2e_request_latency_seconds_count` / `_sum` | vLLM | count / seconds | `instance`, `model_name` | 15s | Same pairing, for end-to-end request latency | Same role as TTFT above, for e2e latency |
| `vllm:generation_tokens_total` | vLLM | tokens (counter) | `instance`, `model_name` | 15s | Cumulative output tokens generated | A2.2 (per-pod delta over the aiperf window proves real traffic, not just a probe hit); `rate()` by pod depicts S2's throughput-scaling story directly |
| `vllm:kv_cache_usage_perc` | vLLM | ratio (0–1) | `instance`, `model_name` | 15s | KV-cache occupancy | Capacity-pressure signal, relevant to S3's lower `GPU_MEMORY_UTILIZATION` headroom story; renamed from `vllm:gpu_cache_usage_perc` in vLLM ≥0.9 |

### Routing / backend discovery

| Metric | Source | Unit | Labels | Granularity | Meaning | Feeds |
|--------|--------|------|--------|-------------|---------|-------|
| `inference_pool_ready_pods` | llm-d router (EPP) | count | `pod`/`instance` (the **EPP's own** pod — this is a pool-wide gauge, not per-backend), `namespace`, `name` (workspace) | chart default (not configured by this repo) | Number of backend pods the EPP has discovered and considers ready to route to | A documented, collect-phase-gated required series; also used directly as the execute-phase readiness gate ([`workflow/bin/40-execute.sh`](../../workflow/bin/40-execute.sh)) proving the router — not just Kubernetes — sees every replica before load starts |
| `inference_pool_per_pod_queue_size` | llm-d router (EPP) | count | `model_server_pod` (the **backend** pod this sample is about — not `pod`, which is the EPP's own pod), `namespace`, `name` | chart default | The router's own per-pod queue-depth view — distinct data path from vLLM's self-reported per-pod metrics above | **S2 distribution view #2**: a router-level cross-check that load is actually balanced across pods, independent of the vLLM-level view — the two disagreeing would itself be a meaningful finding (e.g. an EPP routing bug that vLLM-side metrics alone wouldn't surface) |

### Scenario-specific

See each scenario spec's "Required metrics (delta)" section: S2 reads the infra/inference-execution
series above **per pod** (load-balancing proof); S3 reads them **per node** (shard-split proof,
combined with the `system_fingerprint` check — DCGM alone is not sufficient, see S3 spec A3.2).

---

## 3. Dashboard (T6.4)

Provisioned automatically during the `prepare` phase (`workflow/bin/20-prepare.sh`):

1. An explicit **`Grafana` CR** (`grafana-vm`) and **`GrafanaDatasource` CR** pointing at this
   cluster's own vmselect, both derived directly from k0rdent KOF's own reference implementation
   ([`kof-storage` chart, v1.8.0](https://github.com/k0rdent/kof/tree/v1.8.0/charts/kof-storage/templates/grafana))
   — [`workflow/templates/grafana.yaml.tmpl`](../../workflow/templates/grafana.yaml.tmpl),
   [`grafana-datasource.yaml.tmpl`](../../workflow/templates/grafana-datasource.yaml.tmpl). KOF's
   own Grafana bundling gates these behind an internal `installForTests` flag not meant for
   general reuse, so this repo applies its own copies instead — same CR names/labels/fields
   upstream uses, so the derivation is traceable.
2. **One dashboard** — [`workflow/templates/benchmark-dashboard.json`](../../workflow/templates/benchmark-dashboard.json)
   (plain, importable into any Grafana), scoped to exactly this benchmark's required-metrics and
   acceptance-criteria story: EPP ready-endpoint count and per-pod queue distribution, per-node
   DCGM, per-pod vLLM throughput/concurrency/KV-cache, live-computed average TTFT/e2e latency.

**Viewing it:** the whole cluster (Grafana included) is destroyed at cleanup right after collect —
run with `--keep` (or `--to collect`) to leave it up; the collect phase then prints the exact
`port-forward` command and how to retrieve the auto-generated admin credentials (see
[`workflow/README.md`](../../workflow/README.md)'s Quickstart / RUN_FLAGS section). Without `--keep`,
the dashboard's real value is that it's importable **after the fact** from the durable evidence:
every metric's time series is committed alongside `metrics/*.json` (see §2's "Every series..." note)
and the collect phase's own run-report already summarizes the same gates the dashboard visualizes
— the dashboard is a live convenience during/right after a run, not the only way to see the result.

## 4. Known limitations

- The Grafana instance's `status.dashboards` also picks up kof-mothership's own bundled default
  dashboards (kube-prometheus-stack views, istio, cluster-api, etc.), since they share the same
  `dashboards: grafana` `instanceSelector` label as this repo's own. Most show no data, since this
  benchmark doesn't run those components.
- Metric names in llm-d's EPP have churned across versions upstream (e.g. `inference_pool_ready_pods`
  is reported to have been renamed to `llm_d_epp_ready_endpoints` in some upstream releases) — worth
  rechecking against the metric catalogue above after any llm-d/router version bump.
- This document moves to "Implemented (as-built)" at T6.5, once T6.2's full verification (two
  consecutive clean runs per scenario, all three scenarios) is done, filling in observed example
  values per scenario the same way each scenario spec's tables cite real evidence numbers.
