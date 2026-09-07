# Scenario 2 — verification evidence

Indexes the committed reproducibility evidence for **Scenario 2 (replicated)**. Raw run artifacts
live in a Git LFS tarball alongside this file:

- `../scenario-2.tar.gz` — sanitized artifacts of two consecutive clean runs (`run-1/`, `run-2/`),
  tracked via Git LFS.

> **Status: PASS.** Two consecutive clean-state runs completed on 2026-09-07, both meeting the
> functional acceptance criteria (T4.2): valid completion, aiperf 0 errors, all required metric
> series present, both replicas served, both GPUs loaded, clean teardown. run-2 started 1 s after
> run-1's cleanup, from the now-bare nodes — consecutive from a clean state. Aggregate throughput
> **reproduced** (~2.85× the S1 baseline, within ~2% run-to-run) under least-busy endpoint-picker
> routing (`EPP_PLUGINS_CONFIG=payload-agnostic.yaml`).

Contents, sanitization, and per-run layout are as for Scenario 1 — see
[`../scenario-1/README.md`](../scenario-1/README.md). Runs execute on **two** Nebius L40S VMs (one
per node); sanitization runs in place at cleanup ([`workflow/lib/sanitize.sh`](../../../workflow/lib/sanitize.sh)).

## Runs

| Run | Workflow commit | Nodes / GPU | Model | Start (UTC) | Duration | Verdict |
|-----|-----------------|-------------|-------|-------------|----------|---------|
| run-1 | `feat/t4` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-07T14:17:48Z | ~22 min | **PASS** |
| run-2 | `feat/t4` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-07T14:40:11Z | ~23 min | **PASS** |

† Produced from `feat/t4` (tip `9fb40a7` plus the least-busy-routing change staged on that branch).
Update to the merged commit SHA when the branch is pushed.

## Acceptance (both runs)

| Criterion | run-1 | run-2 |
|---|---|---|
| All phases `ok` (provisioning) | ✅ | ✅ |
| Functional probe — non-empty completion | ✅ | ✅ |
| aiperf load — 0 request errors (`error_summary: []`) | ✅ | ✅ |
| Required metric series present (0 missing) | ✅ | ✅ |
| **A2.1** two serving pods, one per node | ✅ | ✅ |
| **A2.2** both replicas received traffic (`generation_tokens_total` per pod) | ✅ 7549 / 9052 | ✅ 8740 / 6061 |
| **A2.3** both GPUs loaded (`DCGM_FI_DEV_FB_USED`, MiB) | ✅ 43634 / 43634 | ✅ 43634 / 43634 |
| Cleanup — `k0sctl reset`, nodes left bare | ✅ | ✅ |

## Recorded performance (reported, not gated)

Least-busy routing (`payload-agnostic.yaml`) distributes load evenly across the two replicas, so
throughput **reproduces** and scales ~2.85× over the single-replica S1 baseline.

| Metric | run-1 | run-2 | S1 baseline |
|---|---|---|---|
| Output token throughput | 369.13 tok/s | 375.17 tok/s | ~131 tok/s |
| Request throughput | 2.88 req/s | 2.93 req/s | ~1.05 req/s |
| TTFT p50 / p90 | 351.05 / 400.92 ms | 299.55 / 347.22 ms | ~6.5 s |
| Request latency (e2e) p50 / p90 | 3391.05 / 3443.45 ms | 3331.71 / 3388.41 ms | ~9.7 s |
| vs S1 (throughput) | **~2.82×** | **~2.86×** | 1× |

> Earlier runs (2026-09-07 AM) used the chart default routing (`default-plugins.yaml`, prefix-cache
> affinity) and did **not** reproduce — throughput swung ~2.85× / ~1×. Switching the endpoint-picker
> to least-busy routing fixed the distribution; this evidence supersedes those runs.
