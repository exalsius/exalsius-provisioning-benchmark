# Scenario 2 — verification evidence

Indexes the committed reproducibility evidence for **Scenario 2 (replicated)**. Raw run artifacts
live in a Git LFS tarball alongside this file:

- `../scenario-2.tar.gz` — sanitized artifacts of two consecutive clean runs (`run-1/`, `run-2/`),
  tracked via Git LFS.

> **Status: PASS.** Two consecutive clean-state runs completed on 2026-09-14, both meeting the
> functional acceptance criteria (T4.2): valid completion, aiperf 0 errors, all required metric
> series present, the `WorkspaceDeployment` Ready/Available gate, the EPP-endpoint-discovery wait,
> and the per-pod delta-based A2.2 check all passed, both GPUs loaded, clean teardown. run-2 started
> instantly after run-1's cleanup tore down the k0s cluster on both nodes — consecutive from a fresh
> cluster, not a rebooted/bare node (see [Scenario 1 §6](../../scenarios/scenario-1.md#6-known-limitations)).
> Aggregate throughput **reproduced** (~2.7× the S1 baseline, within ~1.4% run-to-run) under
> least-busy endpoint-picker routing (`EPP_PLUGINS_CONFIG=payload-agnostic.yaml`). This evidence
> supersedes the 2026-09-07 runs, which predated the three gates above.

Contents, sanitization, and per-run layout are as for Scenario 1 — see
[`../scenario-1/README.md`](../scenario-1/README.md). Runs execute on **two** Nebius L40S VMs (one
per node); sanitization runs in place at cleanup ([`workflow/lib/sanitize.sh`](../../../workflow/lib/sanitize.sh)).

## Runs

| Run | Workflow commit | Nodes / GPU | Model | Start (UTC) | Duration | Verdict |
|-----|-----------------|-------------|-------|-------------|----------|---------|
| run-1 | `main` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-14T10:05:44Z | ~32 min | **PASS** |
| run-2 | `main` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-14T10:37:49Z | ~24 min | **PASS** |

† Runs were produced from `main` (tip `e0cbb98`, the merged T3+T4 implementation) plus the
WorkspaceDeployment-ready gate, EPP-discovery gate, A2.2 delta check, and doc/dedup fixes staged for
commit alongside this evidence update. Update to the exact commit SHA once committed.

## Acceptance (both runs)

| Criterion | run-1 | run-2 |
|---|---|---|
| All phases `ok` (provisioning) | ✅ | ✅ |
| Functional probe — non-empty completion | ✅ | ✅ |
| aiperf load — 0 request errors (`error_summary: []`) | ✅ | ✅ |
| Required metric series present (0 missing) | ✅ | ✅ |
| `WorkspaceDeployment` Ready/Available condition `True` | ✅ | ✅ |
| EPP reported both replicas discovered before load (`inference_pool_ready_pods`) | ✅ | ✅ |
| **A2.1** two serving pods, one per node | ✅ | ✅ |
| **A2.2** both replicas received traffic — per-pod `generation_tokens_total` delta over the aiperf window (both `> 0`) | ✅ 7092 / 7197 | ✅ 9884 / 8117 |
| **A2.3** both GPUs loaded (`DCGM_FI_DEV_FB_USED`, MiB) | ✅ 43636 / 43636 | ✅ 43636 / 43634 |
| Cleanup — `k0sctl reset` tears down the k0s cluster | ✅ | ✅ |

## Recorded performance (reported, not gated)

Least-busy routing (`payload-agnostic.yaml`) distributes load evenly across the two replicas, so
throughput **reproduces** and scales ~2.7× over the single-replica S1 baseline (see
[`../scenario-1/README.md`](../scenario-1/README.md) for the current S1 figures).

| Metric | run-1 | run-2 | S1 baseline |
|---|---|---|---|
| Output token throughput | 372.92 tok/s | 367.89 tok/s | ~135.0 tok/s |
| Request throughput | 2.91 req/s | 2.87 req/s | ~1.06 req/s |
| TTFT p50 / p90 | 316.68 / 386.97 ms | 382.03 / 417.70 ms | ~6.3 s |
| Request latency (e2e) p50 / p90 | 3389.31 / 3427.11 ms | 3423.34 / 3456.86 ms | ~9.5 s |
| Inter-token latency p50 | 24.19 ms | 23.95 ms | ~24.5 ms |
| vs S1 (throughput) | **~2.76×** | **~2.72×** | 1× |

> Earlier runs (2026-09-07) used the same least-busy routing and also reproduced (~2.85×), but
> predated the WorkspaceDeployment-ready gate, EPP-discovery wait, and per-pod delta-based A2.2
> check — this evidence supersedes them. A separate, still-earlier pair (2026-09-07 AM) used the
> chart's default routing (`default-plugins.yaml`, prefix-cache affinity) and did **not** reproduce
> (~2.85× / ~1×); switching to least-busy routing is what fixed the distribution.
