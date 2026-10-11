# Scenario 1 — verification evidence

Indexes the committed reproducibility evidence for **Scenario 1 (single-node)**. Raw run artifacts
live in a Git LFS tarball alongside this file:

- `../scenario-1.tar.gz` — sanitized artifacts of two consecutive clean runs (`run-1/`, `run-2/`),
  tracked via Git LFS (see repo `.gitattributes`).

> **Status: PASS.** Two consecutive clean-state runs completed on 2026-10-11, both meeting the
> functional acceptance criteria (T3.2, T6.2): the `WorkspaceDeployment` Ready/Available hard gate,
> the pod-placement hard gate (trivial with one pod — `results/pod-placement.txt`), and the
> telemetry gate (all required series present, including the llm-d router's EPP metrics) all passed.
> run-2 started immediately after run-1's cleanup tore down the k0s cluster on the same node —
> consecutive from a fresh cluster, not a rebooted/bare node (see
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
| run-1 | `main` @ `2d2ccac` | Nebius L40S VM (1× L40S 48 GB) | `Qwen/Qwen3-8B` | 2026-10-11T06:46:58Z | ~25 min | **PASS** |
| run-2 | `main` @ `2d2ccac` | Nebius L40S VM (1× L40S 48 GB) | `Qwen/Qwen3-8B` | 2026-10-11T07:11:37Z | ~24 min | **PASS** |

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
| Output token throughput | 520.75 tok/s | 520.97 tok/s |
| Request throughput | 4.07 req/s | 4.07 req/s |
| TTFT p50 / p90 | 402.25 / 461.24 ms | 401.82 / 458.45 ms |
| Request latency (e2e) p50 / p90 | 3839.88 / 3852.76 ms | 3837.77 / 3849.43 ms |
| Inter-token latency p50 | 27.08 ms | 27.04 ms |
| Output sequence length | ~128 tokens | ~128 tokens |

The two runs agree within ~0.05% on throughput and latency — this is the single-node baseline S2
(replica distribution) and S3 (sharding overhead) are compared against.
