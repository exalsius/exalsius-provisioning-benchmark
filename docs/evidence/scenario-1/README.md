# Scenario 1 — verification evidence

This directory indexes the committed reproducibility evidence for **Scenario 1
(single-node)**. The raw run artifacts live in a Git LFS tarball alongside this
file:

- `../scenario-1.tar.gz` — sanitized artifacts of two consecutive clean runs
  (`run-1/`, `run-2/`), tracked via Git LFS (see repo `.gitattributes`).

> **Status: PASS.** Two consecutive clean-state runs completed on 2026-09-03, both meeting the
> functional acceptance criteria (T3.2). run-2 started 1 s after run-1's cleanup, from the now-bare
> node — consecutive from a clean state.

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
48 GB, 8 vCPU, 32 GiB, Ubuntu 24.04) — documented in full in
[`../../scenarios/scenario-1.md` §2.1](../../scenarios/scenario-1.md#21-reference-test-environment-known-good).

| Run | Workflow commit | Node / GPU | Model | Start (UTC) | Duration | Verdict |
|-----|-----------------|------------|-------|-------------|----------|---------|
| run-1 | `feat/t3` † | Nebius L40S VM (1× L40S 48 GB) | `Qwen/Qwen3-8B` | 2026-09-03T04:40:18Z | ~23 min | **PASS** |
| run-2 | `feat/t3` † | Nebius L40S VM (1× L40S 48 GB) | `Qwen/Qwen3-8B` | 2026-09-03T05:03:39Z | ~24 min | **PASS** |

† Runs were produced from the `feat/t3` branch (tip `4b3d796` plus the deploy/scheduling and
sanitization fixes staged on that branch). Update to the merged commit SHA when the branch is pushed
(this is the "permanent link to the commit" the T3.1/T3.2 acceptance points at).

## Acceptance (both runs)

| Criterion | run-1 | run-2 |
|---|---|---|
| All phases `ok` (provisioning) | ✅ | ✅ |
| Functional probe — non-empty completion | ✅ pass | ✅ pass |
| aiperf load — 0 request errors (`error_summary: []`) | ✅ | ✅ |
| Required metric series present (0 missing) | ✅ | ✅ |
| One serving pod on one GPU — `DCGM_FI_DEV_FB_USED` non-zero (A1.1/A1.2) | ✅ 43634 MiB | ✅ |
| Cleanup — `k0sctl reset`, node left bare | ✅ | ✅ |

## Recorded baseline (reported, not gated)

| Metric | run-1 | run-2 |
|---|---|---|
| Output token throughput | 134.24 tok/s | 129.05 tok/s |
| Request throughput | 1.05 req/s | 1.01 req/s |
| TTFT p50 / p90 | 6401.65 / 6439.90 ms | 6784.06 / 6818.52 ms |
| Request latency (e2e) p50 / p90 | 9507.07 / 9529.52 ms | 9890.80 / 9911.67 ms |
| Inter-token latency p50 | 24.46 ms | 24.46 ms |
| Output sequence length | 128 tokens | 128 tokens |

The two runs agree within ~4% on throughput and latency — the single-node baseline S2/S3 are
compared against.
