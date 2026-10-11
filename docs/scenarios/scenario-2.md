# Scenario 2 — Replicated inference (runbook)

Operator-facing runbook for **Scenario 2**: provision **two** GPU nodes, deploy the medium LLM
(`Qwen/Qwen3-8B`) as **two independent replicas** (one whole model per node) behind the shared
llm-d router, drive load across both, collect telemetry, and tear everything down — through the same
containerised workflow as Scenario 1, changed only by `config/scenario-s2.env`.

- **Design spec:** [`../specs/scenario-2-replicated.md`](../specs/scenario-2-replicated.md)
  (inherits [`../specs/common-experiment-setup.md`](../specs/common-experiment-setup.md)).
- **Workflow reference:** [`../../workflow/README.md`](../../workflow/README.md).
- **Reference test environment / shared troubleshooting:** the Scenario 1 runbook
  ([`scenario-1.md`](scenario-1.md)) — S2 uses **two** of the same Nebius L40S VMs.
- **Verification evidence:** [`../evidence/scenario-2/`](../evidence/scenario-2/).

## 1. Prerequisites

Same as [Scenario 1 §1](scenario-1.md#1-prerequisites) except **two** GPU nodes are required
(each an L40S-class 48 GB VM, no pre-installed NVIDIA driver needed — see [Scenario 1 §2.1](scenario-1.md#21-reference-test-environment-known-good)). `NODE_ENDPOINTS` lists both, comma-separated:

```
NODE_ENDPOINTS="10.0.0.26:22,10.0.0.27:22"
```

`HF_TOKEN`, `SSH_USERNAME`, the SSH key, and `RUN_ID` are as for S1.

## 2. Infrastructure configuration

Two nodes become one self-contained k0s cluster (`bench-s2`, control plane co-located on the first).
Topology is fixed by [`workflow/config/scenario-s2.env`](../../workflow/config/scenario-s2.env):

| Setting | Value | Meaning |
|---|---|---|
| `EXPECTED_NODE_COUNT` | 2 | two provided nodes |
| `REPLICAS` | 2 | two model-server pods |
| `GPU_COUNT_PER_REPLICA` | 1 | one GPU per pod |
| `NODES_PER_REPLICA` | 1 | each pod is a whole model → **2 independent copies**, TP=1 |

Both pods are LeaderWorkerSet leaders; a topology-spread preference places one per node, and the
router's endpoint-picker distributes across them using **uniform-random** routing
(`EPP_PLUGINS_CONFIG=random-picker.yaml`, the workflow default) so both replicas reliably receive
traffic regardless of which backend happens to be faster — see
[spec §7](../specs/scenario-2-replicated.md#7-known-limitations) for why the chart's own
least-busy profile (`payload-agnostic.yaml`) isn't used here. Shared defaults
(`WORKSPACE_CPU=2`, `GPU_VENDOR=NVIDIA`,
`GPU_MEMORY_UTILIZATION=0.85`, …) are in `common.env`, same as S1 — 0.85 is the value S3's
cross-node CUDA-graph capture needs, applied to all three scenarios so `DCGM_FI_DEV_FB_USED` stays
comparable between them.

## 3. Execution steps

```bash
cd workflow
make build
make s2 RUN_ID=s2-run-1          # or: make docker-run SCENARIO=s2 RUN_ID=s2-run-1
```

Preset inputs for CI (note the two endpoints):

```bash
export HF_TOKEN=hf_xxx NODE_ENDPOINTS="10.0.0.26:22,10.0.0.27:22" SSH_USERNAME=ubuntu
make docker-run SCENARIO=s2 RUN_ID=s2-run-1 SSH_KEY_PATH=~/.ssh/bench
```

Phases and `RUN_FLAGS` variants are identical to [Scenario 1 §3](scenario-1.md#3-execution-steps).
Before sending load, the execute phase waits for **both** serving leaders to be Ready (not just
one), then additionally waits for the endpoint-picker to report both as discovered
(`inference_pool_ready_pods`) — pod-Ready alone doesn't guarantee the EPP has picked them up yet —
so the aiperf run actually exercises both replicas instead of risking load landing on just one.

## 4. Expected outputs

The artifact layout and the collect-phase metric gate are the same as
[Scenario 1 §4](scenario-1.md#4-expected-outputs). A passing run additionally shows **two** serving
pods (one per node) and both GPUs in use. `run-report.md` reports the aggregate aiperf performance.

## 5. Result interpretation

- **Functional acceptance** (gated): all phases `ok`, functional probe `pass`, aiperf 0 errors,
  0 missing metric series, `WorkspaceDeployment` Ready/Available `True`, both replicas received load
  traffic (A2.2), pod placement OK (A2.1), cleanup tears down the k0s cluster on both nodes.
- **Scenario-2 acceptance** (spec §5):
  - **A2.1** two serving pods, one per node (gated in the collect phase: no two model-server pods
    share a node, recorded in `results/pod-placement.txt`) — spot-check with
    `kubectl -n ws-s2-replicated get pod -l llm-d.ai/inference-serving=true -o wide`.
  - **A2.2** both replicas receive traffic under load (gated in the collect phase): each pod's
    `vllm:generation_tokens_total` **delta** over the aiperf window — the value right before aiperf
    launched vs. the post-run snapshot — must be positive. A raw post-run cumulative value isn't
    enough on its own, since it would also count whatever the functional probe sent to a single pod
    before aiperf ever started.
  - **A2.3** both GPUs loaded — `DCGM_FI_DEV_FB_USED` non-zero for **both** `Hostname`s in `metrics/DCGM_FI_DEV_FB_USED.json`.
  - **A2.4** aggregate throughput recorded and compared to the S1 baseline (~520.9 tok/s). Reported,
    not gated — see [spec §3](../specs/scenario-2-replicated.md#3-expected-outcome) for why
    aggregate throughput is not expected to exceed it at this benchmark's fixed load concurrency.
- **Baseline** (`Qwen/Qwen3-8B`, concurrency 16, 200 requests): both runs distributed load to both
  replicas and passed every functional gate under uniform-random routing
  (`EPP_PLUGINS_CONFIG=random-picker.yaml`) — run-1 516.88 tok/s, run-2 483.02 tok/s (~0.93–0.99× the
  S1 baseline), TTFT p50 120–160 ms. Per-pod traffic split varied run-to-run (63/37 in run-1, roughly
  even in run-2) while both replicas reliably received traffic (A2.2) in both. **A2.3** GPU
  footprint: 39100/39098 MiB (run-1), 39100/39100 MiB (run-2). Full per-run data:
  [`../evidence/scenario-2/`](../evidence/scenario-2/).

## 6. Known limitations

See [spec §7](../specs/scenario-2-replicated.md#7-known-limitations): replication needs the model to
fit one GPU (no larger models — that is S3); at this benchmark's fixed load concurrency, aggregate
throughput tracks the S1 baseline rather than scaling with replica count; placement is a preference.

## 7. Troubleshooting

The shared failure modes (GPU not requested, driver < 580, missing metrics, StorageClass, header,
inotify, aiperf timeout, NGC pull) are in [Scenario 1 §7](scenario-1.md#7-troubleshooting).
Scenario-2-specific:

| Symptom | Cause | Fix |
|---|---|---|
| Only one serving pod (both scheduled, one Pending) | second node not joined, or its GPU not schedulable | check both nodes `Ready` (`bootstrap.log`) and both advertise `nvidia.com/gpu` (GPU operator ready on both) |
| Collect phase dies "pod-placement acceptance not met" (A2.1 fails) | both pods landed on the same node — spread is `ScheduleAnyway` (a preference), only expected if a node lacks a free GPU | check `results/pod-placement.txt`; with 1 GPU/node the GPU request should force one per node — investigate why it didn't |
| Execute phase dies "EPP never reported N ready pool endpoint(s)" | the endpoint-picker hasn't discovered all replicas yet (pod-Ready doesn't imply EPP-discovered) | check `inference_pool_ready_pods` is scraped (router subchart's EPP `ServiceMonitor`); raise `EPP_READY_CHECK_TIMEOUT` (default 180s) only if this is consistently a slow-converge race |
| Collect phase dies "replica-traffic acceptance not met" (A2.2 fails) | endpoint-picker saw one pod, or `LOAD_CONCURRENCY` too low to fan out | compare `metrics/vllm_generation_tokens_total.json` against `metrics/_pre_load_vllm_generation_tokens_total.json` per `instance`; raise `LOAD_CONCURRENCY` |

## 8. Reproduction

Same as [Scenario 1 §8](scenario-1.md#8-reproduction) with `SCENARIO=s2` and a two-node
`NODE_ENDPOINTS`; artifacts are sanitized in place at cleanup:

```bash
cd workflow
make build
export HF_TOKEN=hf_xxx NODE_ENDPOINTS="10.0.0.26:22,10.0.0.27:22" SSH_USERNAME=ubuntu
make docker-verify SCENARIO=s2 COUNT=2 SSH_KEY_PATH=~/.ssh/bench   # s2-run-1 then s2-run-2
./bin/package-evidence.sh s2 s2-run-1 s2-run-2                     # -> docs/evidence/scenario-2.tar.gz
```
