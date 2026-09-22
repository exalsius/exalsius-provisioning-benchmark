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
| **S1 single-node** | ✅ | ✅ 2/2 PASS ([evidence](docs/evidence/scenario-1/)) | ✅ [runbook](docs/scenarios/scenario-1.md) | ✅ DCGM + `vllm:*` | ✅ [as-built](docs/specs/scenario-1-single-node.md) |
| **S2 replicated** | ✅ | ✅ 2/2 PASS¹ ([evidence](docs/evidence/scenario-2/)) | ✅ [runbook](docs/scenarios/scenario-2.md) | ✅ DCGM + `vllm:*` | ✅ [as-built](docs/specs/scenario-2-replicated.md) |
| **S3 sharded** | ✅ | ✅ 2/2 PASS² ([evidence](docs/evidence/scenario-3/)) | ✅ [runbook](docs/scenarios/scenario-3.md) | ✅ DCGM + `vllm:*` | ✅ [as-built](docs/specs/scenario-3-sharded.md) |

Legend: ✅ done · 🟡 pending / draft · ⬜ not started. S1 is verified by two consecutive clean-state
runs on 2026-09-22 (baseline ~135 tok/s, TTFT p50 ~6.3 s), under
[`docs/evidence/scenario-1/`](docs/evidence/scenario-1/). ¹ S2 (T4) passed two consecutive runs
(2026-09-22), load-balanced across both replicas, with **reproducible ~2.8× throughput scaling** over
S1 under least-busy endpoint-picker routing — both scenarios' runs pass the WorkspaceDeployment-ready,
EPP-discovery, (S2) per-replica-traffic delta, and pod-placement hard gates (see the evidence). ² S3
(T5) passed two consecutive runs (2026-09-22) with a single sharded (TP=2) model copy across both
nodes, each verified on distinct nodes by the collect phase's pod-placement hard gate — slower than
S1 (~46 tok/s vs. ~135 tok/s, expected: an 8B model doesn't need sharding, so TP=2 here is pure
cross-node communication overhead) but reproducible (within ~0.6%). All three scenarios share
`GPU_MEMORY_UTILIZATION=0.85` (`workflow/config/common.env`, needed to leave CUDA-graph-capture
headroom under cross-node TP), so the S1 vs. S3 comparison isn't confounded by differing GPU-memory
settings.

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
| [`docs/specs/`](docs/specs/) | Experiment specifications — the [common setup](docs/specs/common-experiment-setup.md) + per-scenario specs (as-built for S1/S2/S3). |
| [`docs/scenarios/`](docs/scenarios/) | Operator runbooks — [Scenario 1](docs/scenarios/scenario-1.md), [Scenario 2](docs/scenarios/scenario-2.md), [Scenario 3](docs/scenarios/scenario-3.md). |
| [`docs/evidence/`](docs/evidence/) | Committed verification evidence (sanitized run artifacts, Git LFS). |

## Status

Scenario 1 (T3) is the **reference implementation** — implemented, verified (two consecutive runs),
and documented. Scenario 2 (T4) reuses the workflow with only per-scenario config, plus a small
readiness refinement so load waits for both replicas and a least-busy endpoint-picker routing
default; it is implemented, documented, and verified by two consecutive PASS runs with reproducible
~2.8× throughput scaling over S1. Scenario 3 (T5) reuses the same workflow at the shared
`GPU_MEMORY_UTILIZATION=0.85` default (`common.env`; cross-node tensor parallelism otherwise OOMs
during CUDA-graph capture); it is implemented, documented, and verified by two consecutive PASS
runs demonstrating a genuine cross-node model shard, with the collect phase's pod-placement hard
gate confirming the leader and worker land on
distinct nodes. A published documentation page is a follow-up.
