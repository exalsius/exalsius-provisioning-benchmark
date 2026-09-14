# Scenario 1 — verification evidence

This directory indexes the committed reproducibility evidence for **Scenario 1
(single-node)**. The raw run artifacts live in a Git LFS tarball alongside this
file:

- `../scenario-1.tar.gz` — sanitized artifacts of two consecutive clean runs
  (`run-1/`, `run-2/`), tracked via Git LFS (see repo `.gitattributes`).

> **Status: PASS.** Two consecutive clean-state runs completed on 2026-09-14, both meeting the
> functional acceptance criteria (T3.2), including the `WorkspaceDeployment` Ready/Available hard
> gate added after the original 2026-09-03 evidence (this evidence supersedes that run — see below).
> run-2 started 1 s after run-1's cleanup tore down the k0s cluster on the same node — consecutive
> from a fresh cluster, not a rebooted/bare node (see
> [`../../scenarios/scenario-1.md` §6](../../scenarios/scenario-1.md#6-known-limitations)).

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
| run-1 | `main` † | Nebius L40S VM (1× L40S 48 GB) | `Qwen/Qwen3-8B` | 2026-09-14T09:08:57Z | ~25 min | **PASS** |
| run-2 | `main` † | Nebius L40S VM (1× L40S 48 GB) | `Qwen/Qwen3-8B` | 2026-09-14T09:33:46Z | ~31 min | **PASS** |

† Runs were produced from `main` (tip `e0cbb98`, the merged T3+T4 implementation) plus the
WorkspaceDeployment-ready gate, EPP-discovery gate, A2.2 delta check, and doc/dedup fixes staged for
commit alongside this evidence update. Update to the exact commit SHA once committed.

## Acceptance (both runs)

| Criterion | run-1 | run-2 |
|---|---|---|
| All phases `ok` (provisioning) | ✅ | ✅ |
| Functional probe — non-empty completion | ✅ pass | ✅ pass |
| aiperf load — 0 request errors (`error_summary: []`) | ✅ | ✅ |
| Required metric series present (0 missing) | ✅ | ✅ |
| `WorkspaceDeployment` Ready/Available condition `True` | ✅ | ✅ |
| Replica received load traffic (per-pod delta over the aiperf window) | ✅ 1/1 | ✅ 1/1 |
| One serving pod on one GPU — `DCGM_FI_DEV_FB_USED` non-zero (A1.1/A1.2) | ✅ 43634 MiB | ✅ 43634 MiB |
| Cleanup — `k0sctl reset` tears down the k0s cluster | ✅ | ✅ |

## Recorded baseline (reported, not gated)

| Metric | run-1 | run-2 |
|---|---|---|
| Output token throughput | 135.59 tok/s | 134.40 tok/s |
| Request throughput | 1.06 req/s | 1.05 req/s |
| TTFT p50 / p90 | 6305.46 / 6339.38 ms | 6391.48 / 6425.62 ms |
| Request latency (e2e) p50 / p90 | 9410.92 / 9434.53 ms | 9497.00 / 9517.81 ms |
| Inter-token latency p50 | 24.46 ms | 24.45 ms |
| Output sequence length | 128 tokens | 128 tokens |

The two runs agree within ~1% on throughput and latency — the single-node baseline S2/S3 are
compared against.
