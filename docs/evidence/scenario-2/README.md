# Scenario 2 — verification evidence

Indexes the committed reproducibility evidence for **Scenario 2 (replicated)**. Raw run artifacts
live in a Git LFS tarball alongside this file:

- `../scenario-2.tar.gz` — sanitized artifacts of two consecutive clean runs (`run-1/`, `run-2/`),
  tracked via Git LFS.

> **Status: PASS.** Two consecutive clean-state runs completed on 2026-09-22, both meeting the
> functional acceptance criteria (T4.2): valid completion, aiperf 0 errors, all required metric
> series present, the `WorkspaceDeployment` Ready/Available gate, the EPP-endpoint-discovery wait,
> the per-pod delta-based A2.2 check, and the pod-placement hard gate (A2.1,
> `results/pod-placement.txt`) all passed, both GPUs loaded, clean teardown. run-2 started instantly
> after run-1's cleanup tore down the k0s cluster on both nodes — consecutive from a fresh cluster,
> not a rebooted/bare node (see [Scenario 1 §6](../../scenarios/scenario-1.md#6-known-limitations)).
> Aggregate throughput **reproduced** (~2.8× the S1 baseline, within ~0.4% run-to-run) under
> least-busy endpoint-picker routing (`EPP_PLUGINS_CONFIG=payload-agnostic.yaml`; current default
> is `random-picker.yaml`, see
> [scenario-2 spec §7](../../specs/scenario-2-replicated.md#7-known-limitations)).
> `GPU_MEMORY_UTILIZATION=0.85` (set in `workflow/config/common.env`, shared across all three
> scenarios).

Contents, sanitization, and per-run layout are as for Scenario 1 — see
[`../scenario-1/README.md`](../scenario-1/README.md). Runs execute on **two** Nebius L40S VMs (one
per node); sanitization runs in place at cleanup ([`workflow/lib/sanitize.sh`](../../../workflow/lib/sanitize.sh)).

## Runs

| Run | Workflow commit | Nodes / GPU | Model | Start (UTC) | Duration | Verdict |
|-----|-----------------|-------------|-------|-------------|----------|---------|
| run-1 | `main` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-22T05:20:06Z | ~23 min | **PASS** |
| run-2 | `main` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-22T05:43:26Z | ~23 min | **PASS** |

† Runs were produced ahead of merge, on the branch that became `main` at tip `f034cdc` (#5, which
adds the pod-placement hard gate and the shared `GPU_MEMORY_UTILIZATION=0.85` default).

## Acceptance (both runs)

| Criterion | run-1 | run-2 |
|---|---|---|
| All phases `ok` (provisioning) | ✅ | ✅ |
| Functional probe — non-empty completion | ✅ | ✅ |
| aiperf load — 0 request errors (`error_summary: []`) | ✅ | ✅ |
| Required metric series present (0 missing) | ✅ | ✅ |
| `WorkspaceDeployment` Ready/Available condition `True` | ✅ | ✅ |
| EPP reported both replicas discovered before load (`inference_pool_ready_pods`) | ✅ | ✅ |
| **A2.1** two serving pods, one per node — collect-phase hard gate, `results/pod-placement.txt` | ✅ | ✅ |
| **A2.2** both replicas received traffic — per-pod `generation_tokens_total` delta over the aiperf window (both `> 0`) | ✅ 6804 / 9741 | ✅ 8836 / 9862 |
| **A2.3** both GPUs loaded (`DCGM_FI_DEV_FB_USED`, MiB) | ✅ 39100 / 39098 | ✅ 39098 / 39100 |
| Cleanup — `k0sctl reset` tears down the k0s cluster | ✅ | ✅ |

## Recorded performance (reported, not gated)

Least-busy routing (`payload-agnostic.yaml`) distributed load evenly across the two replicas on
this reference L40S hardware, so throughput **reproduced** and scaled ~2.8× over the single-replica
S1 baseline (see
[`../scenario-1/README.md`](../scenario-1/README.md) for the S1 figures).

| Metric | run-1 | run-2 | S1 baseline |
|---|---|---|---|
| Output token throughput | 375.65 tok/s | 377.26 tok/s | ~135.0 tok/s |
| Request throughput | 2.93 req/s | 2.95 req/s | ~1.06 req/s |
| TTFT p50 / p90 | 277.81 / 359.66 ms | 320.51 / 345.16 ms | ~6.3 s |
| Request latency (e2e) p50 / p90 | 3344.29 / 3402.51 ms | 3360.91 / 3385.65 ms | ~9.5 s |
| Inter-token latency p50 | 24.14 ms | 23.94 ms | ~24.5 ms |
| vs S1 (throughput) | **~2.78×** | **~2.79×** | 1× |
