# Scenario 1 — verification evidence

Indexes the committed reproducibility evidence for **Scenario 1 (single-node)**. Raw run artifacts
live in a Git LFS tarball alongside this file:

- `../scenario-1.tar.gz` — sanitized artifacts of two consecutive clean runs (`run-1/`, `run-2/`),
  tracked via Git LFS (see repo `.gitattributes`).

> **Status: PASS.** Two consecutive clean-state runs completed on 2026-09-22, both meeting the
> functional acceptance criteria (T3.2): the `WorkspaceDeployment` Ready/Available hard gate and the
> pod-placement hard gate (trivial with one pod — `results/pod-placement.txt`) both passed. run-2
> started 2 s after run-1's cleanup tore down the k0s cluster on the same node — consecutive from a
> fresh cluster, not a rebooted/bare node (see
> [`../../scenarios/scenario-1.md` §6](../../scenarios/scenario-1.md#6-known-limitations)).
> `GPU_MEMORY_UTILIZATION=0.85` (set in `workflow/config/common.env`, shared across all three
> scenarios so `DCGM_FI_DEV_FB_USED` stays comparable between them).

## What the tarball contains (per run)

Each of `run-1/` and `run-2/` holds the sanitized subset of
`workflow/runs/s1/<run-id>/`:

| File / dir | What it evidences |
|---|---|
| `phases.tsv` | Per-phase status ledger — all `ok` (T3.1 execution-log evidence). |
| `run-report.md` | Functional acceptance summary + recorded aiperf performance. |
| `metrics/_present.txt`, `metrics/_missing.txt` | Telemetry gate — `_missing.txt` empty. |
| `metrics/*.json` | Snapshot of each required series (DCGM + `vllm:*`). |
| `results/functional.json` | Non-empty completion from the functional probe. |
| `results/aiperf.json`, `results/aiperf.log` | Load export, 0 request errors. |
| `config.env` | Resolved parameters (secrets excluded). |
| `*.log` | preflight / bootstrap / prepare / deploy / execute / collect / cleanup logs. |
| `manifests/` | Rendered `k0sctl.yaml` + applied CRDs (HF token redacted). |

**Sanitization** is applied **in place at the end of each run's cleanup phase**
([`workflow/lib/sanitize.sh`](../../../workflow/lib/sanitize.sh); `package-evidence.sh` re-applies it
to the copy as a safety net): the kubeconfig is dropped, and the SSH username, SSH key path, node
public/private addresses, node hostname, and any Hugging Face token are redacted across **all**
files (node identities become `NODE_1`, `NODE_HOST_1`, `NODE_PRIVIP_1`, …). Cluster-internal pod IPs
and hardware ids are left as-is.

## Runs

Both runs were executed on the reference test environment — a **Nebius L40S VM** (1× NVIDIA L40S
48 GB, 8 vCPU, 32 GiB, plain Ubuntu 24.04 image with no pre-installed NVIDIA driver — the GPU
Operator installed one during `prepare`, confirmed by both runs' `prepare.log`
(`--set driver.enabled=true`)) — documented in full in
[`../../scenarios/scenario-1.md` §2.1](../../scenarios/scenario-1.md#21-reference-test-environment-known-good).

| Run | Workflow commit | Node / GPU | Model | Start (UTC) | Duration | Verdict |
|-----|-----------------|------------|-------|-------------|----------|---------|
| run-1 | `main` † | Nebius L40S VM (1× L40S 48 GB) | `Qwen/Qwen3-8B` | 2026-09-22T06:22:36Z | ~23 min | **PASS** |
| run-2 | `main` † | Nebius L40S VM (1× L40S 48 GB) | `Qwen/Qwen3-8B` | 2026-09-22T06:45:43Z | ~23 min | **PASS** |

† Runs were produced ahead of merge, on the branch that became `main` at tip `f034cdc` (#5, which
adds the pod-placement hard gate and the shared `GPU_MEMORY_UTILIZATION=0.85` default).

## Acceptance (both runs)

| Criterion | run-1 | run-2 |
|---|---|---|
| All phases `ok` (provisioning) | ✅ | ✅ |
| Functional probe — non-empty completion | ✅ pass | ✅ pass |
| aiperf load — 0 request errors (`error_summary: []`) | ✅ | ✅ |
| Required metric series present (0 missing) | ✅ | ✅ |
| `WorkspaceDeployment` Ready/Available condition `True` | ✅ | ✅ |
| Replica received load traffic (per-pod delta over the aiperf window) | ✅ 1/1 | ✅ 1/1 |
| Pod placement — trivial with one pod (`results/pod-placement.txt`) | ✅ | ✅ |
| **A1.1** exactly one serving pod | ✅ | ✅ |
| **A1.2** `DCGM_FI_DEV_FB_USED` non-zero on the single GPU (MiB) | ✅ 39098 | ✅ 39098 |
| Cleanup — `k0sctl reset` tears down the k0s cluster | ✅ | ✅ |

## Recorded performance (reported, not gated)

| Metric | run-1 | run-2 |
|---|---|---|
| Output token throughput | 134.92 tok/s | 135.17 tok/s |
| Request throughput | 1.05 req/s | 1.06 req/s |
| TTFT p50 / p90 | 6349.85 / 6386.12 ms | 6334.55 / 6369.42 ms |
| Request latency (e2e) p50 / p90 | 9458.41 / 9482.09 ms | 9438.82 / 9464.49 ms |
| Inter-token latency p50 | 24.48 ms | 24.45 ms |
| Output sequence length | 128 tokens | 128 tokens |

The two runs agree within ~0.2% on throughput and latency — this is the single-node baseline S2
(throughput scaling) and S3 (sharding overhead) are compared against.
