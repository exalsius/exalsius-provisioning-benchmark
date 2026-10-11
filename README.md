# Exalsius provisioning & experimentation benchmark (WP3)

A scripted, **reproducible** benchmark that provisions an Exalsius-managed compute environment from
a set of provided compute instances (`SSH IP:Port`) and deploys a curated set of minimal LLM
inference workspaces. It lets a third party reproduce the provisioning process, execute predefined
deployment scenarios, and validate functionality and telemetry collection — using **only public
Exalsius / OSS components**, no SaaS.

Each run bootstraps a fresh single k0s cluster **directly on the provided nodes** (management ==
target), prepares it in place (storage, GPU operator, k0rdent/KCM, KOF observability, the
`exalsius-operator`), adopts it into k0rdent, deploys the scenario workload, exercises it, collects
telemetry, and tears everything down. One reusable, containerised workflow drives every scenario.

```
bootstrap → prepare → deploy → execute → collect → cleanup      (+ a preflight gate)
```

## Scenarios

All three serve the **same** medium model (`MODEL_ID`, default `Qwen/Qwen3-8B`); only the topology
differs. Topology: `tensor-parallel size = NODES_PER_REPLICA × GPU_COUNT_PER_REPLICA`,
`model copies = REPLICAS / NODES_PER_REPLICA`.

| | Nodes | `REPLICAS` | `GPU_COUNT_PER_REPLICA` | `NODES_PER_REPLICA` | Meaning |
|--|:--:|:--:|:--:|:--:|--|
| **S1** single-node | 1 | 1 | 1 | 1 | one model on one GPU (TP=1) |
| **S2** replicated | 2 | 2 | 1 | 1 | two independent models, one GPU each |
| **S3** sharded | 2 | 2 | 1 | 2 | one model sharded across 2 nodes (TP=2) |

## Capability matrix

| Scenario | Implemented | Verified (2 clean runs) | Docs | Telemetry | Spec |
|----------|:-----------:|:-----------------------:|:----:|:---------:|:----:|
| **S1 single-node** | ✅ | ✅ 2/2 PASS ([evidence](docs/evidence/scenario-1/)) | ✅ [runbook](docs/scenarios/scenario-1.md) | ✅ DCGM + `vllm:*` + EPP¹ | ✅ [as-built](docs/specs/scenario-1-single-node.md) |
| **S2 replicated** | ✅ | ✅ 2/2 PASS ([evidence](docs/evidence/scenario-2/)) | ✅ [runbook](docs/scenarios/scenario-2.md) | ✅ DCGM + `vllm:*` + EPP¹ | ✅ [as-built](docs/specs/scenario-2-replicated.md) |
| **S3 sharded** | ✅ | ✅ 2/2 PASS ([evidence](docs/evidence/scenario-3/)) | ✅ [runbook](docs/scenarios/scenario-3.md) | ✅ DCGM + `vllm:*` + EPP¹ | ✅ [as-built](docs/specs/scenario-3-sharded.md) |

Legend: ✅ done · 🟡 pending / draft · ⬜ not started. All three scenarios are verified by two
consecutive clean-state runs on 2026-10-11 (`main` @ `2d2ccac`), each gated on the
`WorkspaceDeployment`-ready, EPP-discovery, telemetry (0 missing required series), and pod-placement
conditions common to every scenario, plus each scenario's own acceptance criteria — see the linked
evidence for full per-run data. **S1** (single GPU): ~520.9 tok/s, TTFT p50 ~0.4 s. **S2** (two
independent replicas, `EPP_PLUGINS_CONFIG=random-picker.yaml` — uniform-random routing, see
[scenario-2 spec §7](docs/specs/scenario-2-replicated.md#7-known-limitations) for why the chart's
least-busy alternative isn't used): both replicas verifiably receive traffic every run (A2.2); at
this benchmark's fixed load concurrency, aggregate throughput tracks the S1 baseline (~0.93–0.99×)
rather than scaling with replica count — the demonstrated value is correct horizontal distribution,
not increased throughput. **S3** (one model sharded TP=2 across two nodes): ~61.8 tok/s, ~0.12× the
S1 baseline — cross-node synchronization overhead dominates once per-GPU compute is this fast (the
8B model doesn't need sharding; S3 demonstrates a genuine cross-node shard, not a throughput win).
All three scenarios share `GPU_MEMORY_UTILIZATION=0.85` (`workflow/config/common.env`), so the
comparisons aren't confounded by differing GPU-memory settings. ¹ The collect-phase telemetry gate
also includes the llm-d router's EPP pool-readiness (`inference_pool_ready_pods`) and per-backend
queue-depth (`inference_pool_per_pod_queue_size`, a routing-pressure diagnostic, not a
load-balancing proof) gauges, plus the vLLM TTFT/e2e-latency `_sum` series for live-queryable
average latency — see the [Telemetry Specification](docs/specs/telemetry.md).

## Quickstart

The only host requirement is **Docker** — every tool is bundled in the workflow image. Full details
in [`workflow/README.md`](workflow/README.md); the minimal path:

```bash
cd workflow
make build                       # build the workflow container (once)
make s1 RUN_ID=s1-run-1          # run Scenario 1 end-to-end (prompts for node/SSH/HF token)
```

Preset inputs to skip prompts (CI):

```bash
export HF_TOKEN=hf_xxx NODE_ENDPOINTS="10.0.0.26:22" SSH_USERNAME=ubuntu
make docker-run SCENARIO=s1 RUN_ID=s1-run-1 SSH_KEY_PATH=~/.ssh/bench
```

See the [Scenario 1 runbook](docs/scenarios/scenario-1.md) for prerequisites, expected outputs,
result interpretation, troubleshooting, and reproduction.

## Repository layout

| Path | What |
|------|------|
| [`workflow/`](workflow/) | The reusable containerised end-to-end workflow (phase scripts, config, templates, Dockerfile, Makefile). See [`workflow/README.md`](workflow/README.md). |
| [`docs/specs/`](docs/specs/) | Experiment specifications — the [common setup](docs/specs/common-experiment-setup.md), per-scenario specs (as-built for S1/S2/S3), and the [Telemetry Specification](docs/specs/telemetry.md) (T6.1). |
| [`docs/scenarios/`](docs/scenarios/) | Operator runbooks — [Scenario 1](docs/scenarios/scenario-1.md), [Scenario 2](docs/scenarios/scenario-2.md), [Scenario 3](docs/scenarios/scenario-3.md). |
| [`docs/evidence/`](docs/evidence/) | Committed verification evidence (sanitized run artifacts, Git LFS). |
| [`workflow/templates/benchmark-dashboard.json`](workflow/templates/benchmark-dashboard.json) | This repo's own Grafana dashboard (plain, importable JSON), auto-provisioned during `prepare`. |

## Status

All three scenarios (T3/T4/T5) are implemented, documented, and verified by two consecutive
clean-state PASS runs each. Scenario 1 is the single-GPU reference implementation. Scenario 2 runs
two independent replicas behind the shared llm-d router, routed uniform-at-random
(`EPP_PLUGINS_CONFIG=random-picker.yaml` — see [scenario-2 spec
§7](docs/specs/scenario-2-replicated.md#7-known-limitations) for why the chart's least-busy
alternative isn't used), with both replicas verified to receive traffic every run (A2.2). Scenario 3
shards one model copy across two nodes (TP=2) at the shared `GPU_MEMORY_UTILIZATION=0.85` default
(`common.env`; needed to leave CUDA-graph-capture headroom under cross-node tensor parallelism),
with the collect phase's pod-placement hard gate confirming the leader and worker land on distinct
nodes.

**Observability (T6)** is implemented and verified on all three scenarios (two consecutive
clean-state runs each): [`docs/specs/telemetry.md`](docs/specs/telemetry.md) documents every
collected metric's source/unit/labels/interpretation (vLLM, DCGM, and the llm-d router's EPP
pool-readiness and per-backend queue-depth gauges), each collected as a time series over the run's
serving window. `prepare` provisions an explicit `Grafana` + `GrafanaDatasource` CR pair (derived
from k0rdent KOF's own reference implementation) wired to this cluster's own VictoriaMetrics, plus
this repo's own [run-overview dashboard](workflow/templates/benchmark-dashboard.json) — viewable by
running with `--keep` (the cluster, Grafana included, is destroyed at cleanup otherwise; see
[`workflow/README.md`](workflow/README.md)).
