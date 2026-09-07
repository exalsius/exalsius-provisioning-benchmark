# Scenario 2 — verification evidence

Indexes the committed reproducibility evidence for **Scenario 2 (replicated)**. Raw run artifacts
live in a Git LFS tarball alongside this file:

- `../scenario-2.tar.gz` — sanitized artifacts of two consecutive clean runs (`run-1/`, `run-2/`),
  tracked via Git LFS.

> **Status: PASS (functional).** Two consecutive clean-state runs completed on 2026-09-07, both
> meeting the functional acceptance criteria (T4.2): valid completion, aiperf 0 errors, all required
> metric series present, both replicas served, both GPUs loaded, clean teardown. run-2 started 1 s
> after run-1's cleanup, from the now-bare nodes — consecutive from a clean state.
>
> ⚠️ **Performance did not reproduce** (recorded, not gated — see below).

Contents, sanitization, and per-run layout are as for Scenario 1 — see
[`../scenario-1/README.md`](../scenario-1/README.md). Runs execute on **two** Nebius L40S VMs (one
per node); sanitization runs in place at cleanup ([`workflow/lib/sanitize.sh`](../../../workflow/lib/sanitize.sh)).

## Runs

| Run | Workflow commit | Nodes / GPU | Model | Start (UTC) | Duration | Verdict |
|-----|-----------------|-------------|-------|-------------|----------|---------|
| run-1 | `feat/t4` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-07T09:57:18Z | ~23 min | **PASS** |
| run-2 | `feat/t4` † | 2× Nebius L40S VM (1× L40S 48 GB each) | `Qwen/Qwen3-8B` | 2026-09-07T10:20:05Z | ~23 min | **PASS** |

† Produced from `feat/t4` (tip `eca427f` plus the readiness refinement staged on that branch).
Update to the merged commit SHA when the branch is pushed.

## Acceptance (both runs)

| Criterion | run-1 | run-2 |
|---|---|---|
| All phases `ok` (provisioning) | ✅ | ✅ |
| Functional probe — non-empty completion | ✅ | ✅ |
| aiperf load — 0 request errors (`error_summary: []`) | ✅ | ✅ |
| Required metric series present (0 missing) | ✅ | ✅ |
| **A2.1** two serving pods, one per node | ✅ | ✅ |
| **A2.2** both replicas received traffic (`generation_tokens_total` per pod) | ✅ 8086 / 10881 | ✅ 7861 / 6332 |
| **A2.3** both GPUs loaded (`DCGM_FI_DEV_FB_USED`, MiB) | ✅ 43636 / 43636 | ✅ 43634 / 43634 |
| Cleanup — `k0sctl reset`, nodes left bare | ✅ | ✅ |

## Recorded performance (reported, not gated)

| Metric | run-1 | run-2 | S1 baseline |
|---|---|---|---|
| Output token throughput | 373.49 tok/s | 132.91 tok/s | ~131 tok/s |
| Request throughput | 2.92 req/s | 1.04 req/s | ~1.05 req/s |
| TTFT p50 / p90 | 288.84 / 378.48 ms | 6522.33 / 6530.15 ms | ~6.5 s |
| Request latency (e2e) p50 / p90 | 3352.74 / 3421.03 ms | 9596.16 / 9608.09 ms | ~9.7 s |
| vs S1 (throughput) | **~2.85×** | **~1.0×** | 1× |

**Scaling did not reproduce.** Both runs load-balanced to both replicas (A2.2), but aggregate
throughput swung from ~2.85× the S1 baseline (run-1) to ~1× (run-2, statistically identical to a
single replica — high TTFT = requests queued on one replica). The likely cause is the llm-d router's
default endpoint-picker profile (`default-plugins.yaml`), which weights **prefix-cache affinity over
least-load** — the chart notes *"traffic across replicas is deliberately not even; use
`payload-agnostic.yaml` for least-busy routing."* Under the synthetic aiperf workload, concurrent
load can concentrate on one replica (run-2) rather than spread (run-1). Switching the EPP to
`payload-agnostic.yaml` would even the distribution; this is a follow-up, and performance is recorded
rather than gated.
