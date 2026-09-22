# Scenario 3 — verification evidence

Indexes the committed reproducibility evidence for **Scenario 3 (sharded)**. Raw run artifacts
live in a Git LFS tarball alongside this file:

- `../scenario-3.tar.gz` — sanitized artifacts of two consecutive clean runs (`run-1/`, `run-2/`),
  tracked via Git LFS.

> **Status: PASS.** Two consecutive clean-state runs completed on 2026-09-22, both meeting the
> functional acceptance criteria (T5.2): valid completion, aiperf 0 errors, all required metric
> series present, the `WorkspaceDeployment` Ready/Available gate and the EPP-endpoint-discovery
> wait both passed, the pod-placement hard gate confirmed both shard pods on distinct nodes
> (`results/pod-placement.txt`, collect-phase `_check_pod_placement`), clean teardown. run-2 started
> instantly after run-1's cleanup tore down the k0s cluster on both nodes — consecutive from a
> fresh cluster, not a rebooted/bare node (see [Scenario 1 §6](../../scenarios/scenario-1.md#6-known-limitations)).
> `GPU_MEMORY_UTILIZATION=0.85` (set in `workflow/config/common.env`, shared across all three
> scenarios) leaves the headroom TP=2 needs for CUDA-graph capture once cross-node NCCL buffers are
> added.

Contents, sanitization, and per-run layout are as for Scenario 1 — see
[`../scenario-1/README.md`](../scenario-1/README.md). Runs execute on **two** Nebius L40S VMs (one
per node); sanitization runs in place at cleanup ([`workflow/lib/sanitize.sh`](../../../workflow/lib/sanitize.sh)).

## Runs

| Run | Workflow commit | Nodes / GPU | Model | Start (UTC) | Duration | Verdict |
|-----|-----------------|-------------|-------|-------------|----------|---------|
| run-1 | `main` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-22T04:11:41Z | ~32 min | **PASS** |
| run-2 | `main` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-22T04:43:58Z | ~31 min | **PASS** |

† Runs were produced ahead of merge, from the branch that adds the pod-placement hard gate and the
shared `GPU_MEMORY_UTILIZATION=0.85` default. Update to the exact `main` commit SHA once merged.

## Acceptance (both runs)

| Criterion | run-1 | run-2 |
|---|---|---|
| All phases `ok` (provisioning) | ✅ | ✅ |
| Functional probe — non-empty completion | ✅ | ✅ |
| aiperf load — 0 request errors (`error_summary: []`) | ✅ | ✅ |
| Required metric series present (0 missing) | ✅ | ✅ |
| `WorkspaceDeployment` Ready/Available condition `True` | ✅ | ✅ |
| Model copy received load traffic (per-pod delta over the aiperf window) | ✅ 1/1 | ✅ 1/1 |
| EPP reported the shard leader discovered before load (`inference_pool_ready_pods`) | ✅ | ✅ |
| **A3.1** one logical model copy, two pods (leader + worker) on distinct nodes — collect-phase hard gate, `results/pod-placement.txt` | ✅ | ✅ |
| **A3.2** both GPUs used — `DCGM_FI_DEV_FB_USED` non-zero on both nodes (MiB) | ✅ 40994 / 40994 | ✅ 40994 / 40994 |
| **A3.3** functional probe coherent, `system_fingerprint` confirms TP=2 (`vllm-0.26.0-tp2-...`) | ✅ | ✅ |
| **A3.4** load probe 0 errors despite cross-node path | ✅ | ✅ |
| Cleanup — `k0sctl reset` tears down the k0s cluster | ✅ | ✅ |

The actual sharding proof is A3.1 (leader + worker on two distinct single-GPU nodes) combined with
A3.3 (`system_fingerprint` reporting `tp2`, confirming the engine genuinely initialized with
tensor-parallel size 2). `DCGM_FI_DEV_FB_USED` above only confirms both GPUs are in use — it is
**not** a split-proof: S1 and S3 run at the same `GPU_MEMORY_UTILIZATION=0.85`, yet S3's
per-node figure (40994 MiB) is actually slightly *higher* than S1's full-copy figure (39098 MiB),
not half of it, because `DCGM_FI_DEV_FB_USED` mostly reflects vLLM's configured reservation cap
(driven by `gpu_memory_utilization` × VRAM) rather than the actual model-weight footprint — so it
wouldn't drop even if the split were fake. This is confirmed by real data now, not just argued from
first principles.

## Recorded performance (reported, not gated)

Slower than the single-node S1 baseline. This is expected cross-node communication overhead (the
8B model doesn't need sharding, so TP=2 here trades pure overhead for no compute benefit). S1 and
S3 run at the same `GPU_MEMORY_UTILIZATION=0.85`, so the comparison isn't confounded by differing
KV-cache capacity between them.

| Metric | run-1 | run-2 | S1 baseline |
|---|---|---|---|
| Output token throughput | 45.99 tok/s | 45.70 tok/s | ~135.0 tok/s |
| Request throughput | 0.36 req/s | 0.36 req/s | ~1.06 req/s |
| TTFT p50 / p90 | 13783.33 / 15794.70 ms | 14075.87 / 15794.26 ms | ~6.3 s |
| Request latency (e2e) p50 / p90 | 27768.07 / 27824.91 ms | 27946.29 / 28001.99 ms | ~9.5 s |
| Inter-token latency p50 | 110.13 ms | 109.22 ms | ~24.5 ms |
| vs S1 (throughput) | **~0.34×** | **~0.34×** | 1× |

The two runs agree within ~0.6% on throughput and ~2.1% on TTFT. Both scenarios run at the same
`GPU_MEMORY_UTILIZATION=0.85` (see [`../scenario-1/README.md`](../scenario-1/README.md) for S1's
figures), so the ~3× TTFT gap and ~3× throughput gap between S1 and S3 reflect cross-node
communication overhead, not a difference in memory-utilization setting.
