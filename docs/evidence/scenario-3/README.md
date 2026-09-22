# Scenario 3 — verification evidence

Indexes the committed reproducibility evidence for **Scenario 3 (sharded)**. Raw run artifacts
live in a Git LFS tarball alongside this file:

- `../scenario-3.tar.gz` — sanitized artifacts of two consecutive clean runs (`run-1/`, `run-2/`),
  tracked via Git LFS.

> **Status: PASS.** Two consecutive clean-state runs completed on 2026-09-16, both meeting the
> functional acceptance criteria (T5.2): valid completion, aiperf 0 errors, all required metric
> series present, the `WorkspaceDeployment` Ready/Available gate and the EPP-endpoint-discovery
> wait both passed, both shard pods on distinct nodes, clean teardown. run-2 started instantly
> after run-1's cleanup tore down the k0s cluster on both nodes — consecutive from a fresh
> cluster, not a rebooted/bare node (see [Scenario 1 §6](../../scenarios/scenario-1.md#6-known-limitations)).
> Requires `GPU_MEMORY_UTILIZATION=0.85` (vs. S1/S2's chart-default 0.95, set in
> `workflow/config/scenario-s3.env`) — at 0.95 both shards reliably hit `CUDA out of memory` during
> CUDA-graph capture once cross-node NCCL buffers are added; earlier runs without this override
> crash-looped indefinitely and are not included here.

Contents, sanitization, and per-run layout are as for Scenario 1 — see
[`../scenario-1/README.md`](../scenario-1/README.md). Runs execute on **two** Nebius L40S VMs (one
per node); sanitization runs in place at cleanup ([`workflow/lib/sanitize.sh`](../../../workflow/lib/sanitize.sh)).

## Runs

| Run | Workflow commit | Nodes / GPU | Model | Start (UTC) | Duration | Verdict |
|-----|-----------------|-------------|-------|-------------|----------|---------|
| run-1 | `main` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-16T16:28:08Z | ~32 min | **PASS** |
| run-2 | `main` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-16T16:59:49Z | ~32 min | **PASS** |

† Runs were produced from `main` (tip `b83428c`) plus the `GPU_MEMORY_UTILIZATION` fix and the
reconciled `docs/specs/scenario-3-sharded.md` staged for commit alongside this evidence. Update to
the exact commit SHA once committed.

## Acceptance (both runs)

| Criterion | run-1 | run-2 |
|---|---|---|
| All phases `ok` (provisioning) | ✅ | ✅ |
| Functional probe — non-empty completion | ✅ | ✅ |
| aiperf load — 0 request errors (`error_summary: []`) | ✅ | ✅ |
| Required metric series present (0 missing) | ✅ | ✅ |
| `WorkspaceDeployment` Ready/Available condition `True` | ✅ | ✅ |
| EPP reported the shard leader discovered before load (`inference_pool_ready_pods`) | ✅ | ✅ |
| **A3.1** one logical model copy, two pods (leader + worker) on distinct nodes | ✅ | ✅ |
| **A3.2** both GPUs used — `DCGM_FI_DEV_FB_USED` non-zero on both nodes (MiB) | ✅ 40994 / 40994 | ✅ 40994 / 40994 |
| **A3.3** functional probe coherent, `system_fingerprint` confirms TP=2 (`vllm-0.26.0-tp2-...`) | ✅ | ✅ |
| **A3.4** load probe 0 errors despite cross-node path | ✅ | ✅ |
| Cleanup — `k0sctl reset` tears down the k0s cluster | ✅ | ✅ |

The actual sharding proof is A3.1 (leader + worker on two distinct single-GPU nodes) combined with
A3.3 (`system_fingerprint` reporting `tp2`, confirming the engine genuinely initialized with
tensor-parallel size 2). `DCGM_FI_DEV_FB_USED` above only confirms both GPUs are in use — S3 runs
with `GPU_MEMORY_UTILIZATION=0.85` vs. S1's `0.95`, so vLLM's memory-reservation sizing differs
between them and the two figures aren't directly comparable as a "half the footprint" ratio.

## Recorded performance (reported, not gated)

Slower than the single-node S1 baseline. Part of this is expected cross-node communication
overhead (the 8B model doesn't need sharding, so TP=2 here trades pure overhead for no compute
benefit), but S3 also runs at a lower `GPU_MEMORY_UTILIZATION` (0.85 vs. S1's 0.95, needed to avoid
a CUDA-graph-capture OOM under TP=2 — see the note above), which affects available KV-cache
capacity and isn't controlled for here. These figures reflect the S3 configuration as a whole, not
an isolated measurement of communication overhead.

| Metric | run-1 | run-2 | S1 baseline |
|---|---|---|---|
| Output token throughput | 45.23 tok/s | 45.05 tok/s | ~135.0 tok/s |
| Request throughput | 0.35 req/s | 0.35 req/s | ~1.06 req/s |
| TTFT p50 / p90 | 14028.24 / 16051.90 ms | 14241.28 / 16087.79 ms | ~6.3 s |
| Request latency (e2e) p50 / p90 | 28235.93 / 28294.10 ms | 28362.72 / 28407.01 ms | ~9.5 s |
| Inter-token latency p50 | 111.88 ms | 111.19 ms | ~24.5 ms |

The two runs agree within ~0.4% on throughput and ~1.5% on TTFT.
