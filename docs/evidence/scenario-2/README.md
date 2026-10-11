# Scenario 2 — verification evidence

Indexes the committed reproducibility evidence for **Scenario 2 (replicated)**. Raw run artifacts
live in a Git LFS tarball alongside this file:

- `../scenario-2.tar.gz` — sanitized artifacts of two consecutive clean runs (`run-1/`, `run-2/`),
  tracked via Git LFS.

> **Status: PASS.** Two consecutive clean-state runs completed on 2026-10-11, both meeting the
> functional acceptance criteria (T4.2, T6.2): valid completion, aiperf 0 errors, all required
> metric series present (including the llm-d router's EPP metrics), the `WorkspaceDeployment`
> Ready/Available gate, the EPP-endpoint-discovery wait, the per-pod delta-based A2.2 check, and the
> pod-placement hard gate (A2.1, `results/pod-placement.txt`) all passed, both GPUs loaded, clean
> teardown. run-2 started immediately after run-1's cleanup tore down the k0s cluster on both nodes
> — consecutive from a fresh cluster, not a rebooted/bare node (see
> [Scenario 1 §6](../../scenarios/scenario-1.md#6-known-limitations)). Routing uses
> `EPP_PLUGINS_CONFIG=random-picker.yaml` (uniform-random selection across replicas — see
> [scenario-2 spec §7](../../specs/scenario-2-replicated.md#7-known-limitations)).
> `GPU_MEMORY_UTILIZATION=0.85` (set in `workflow/config/common.env`, shared across all three
> scenarios).

Contents, sanitization, and per-run layout are as for Scenario 1 — see
[`../scenario-1/README.md`](../scenario-1/README.md). Runs execute on **two** Nebius L40S VMs (one
per node); sanitization runs in place at cleanup ([`workflow/lib/sanitize.sh`](../../../workflow/lib/sanitize.sh)).

## Runs

| Run | Workflow commit | Nodes / GPU | Model | Start (UTC) | Duration | Verdict |
|-----|-----------------|-------------|-------|-------------|----------|---------|
| run-1 | `main` @ `2d2ccac` | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-10-11T08:21:00Z | ~23 min | **PASS** |
| run-2 | `main` @ `2d2ccac` | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-10-11T08:44:12Z | ~24 min | **PASS** |

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
| **A2.2** both replicas received traffic — per-pod `generation_tokens_total` delta over the aiperf window (both `> 0`) | ✅ 8484 / 4722 | ✅ 5252 / 5483 |
| **A2.3** both GPUs loaded (`DCGM_FI_DEV_FB_USED`, MiB) | ✅ 39100 / 39098 | ✅ 39100 / 39100 |
| Cleanup — `k0sctl reset` tears down the k0s cluster | ✅ | ✅ |

## Recorded performance (reported, not gated)

`random-picker.yaml` picks a backend uniformly at random per request rather than cycling
sequentially, so the exact token split between replicas varies run-to-run (63/37 in run-1, roughly
even in run-2) while both reliably receive traffic (A2.2). At this benchmark's load parameters
(`LOAD_CONCURRENCY=16`, not scaled with replica count), the two replicas split one fixed pool of
in-flight requests rather than each receiving a full independent load, so **aggregate** throughput
tracks the single-replica S1 baseline rather than multiplying it — S2's demonstrated value here is
correct horizontal load distribution (A2.2: both replicas independently verified to serve traffic),
not increased aggregate throughput. See
[`../scenario-1/README.md`](../scenario-1/README.md) for the S1 figures.

| Metric | run-1 | run-2 | S1 baseline |
|---|---|---|---|
| Output token throughput | 516.88 tok/s | 483.02 tok/s | ~520.9 tok/s |
| Request throughput | 4.04 req/s | 3.77 req/s | ~4.07 req/s |
| TTFT p50 / p90 | 119.5 / 227.46 ms | 158.02 / 2973.71 ms | ~402 / 460 ms |
| Request latency (e2e) p50 / p90 | 3394.17 / 3540.11 ms | 3410.7 / 6728.21 ms | ~3839 / 3851 ms |
| Inter-token latency p50 | 25.65 ms | 25.44 ms | ~27.1 ms |
| vs S1 (throughput) | **~0.99×** | **~0.93×** | 1× |
