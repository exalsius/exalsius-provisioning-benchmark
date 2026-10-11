# Scenario 3 — Sharded inference (runbook)

Operator-facing runbook for **Scenario 3**: provision **two** GPU nodes, deploy the medium LLM
(`Qwen/Qwen3-8B`) as a **single logical model copy tensor-parallel-split across both nodes**
(a LeaderWorkerSet leader + worker cooperating over NCCL), drive load against it, collect
telemetry, and tear everything down — through the same containerised workflow as Scenario 1,
changed only by `config/scenario-s3.env` (`GPU_MEMORY_UTILIZATION=0.85` is the shared `common.env`
default across all three scenarios, not S3-specific — see §2).

- **Design spec:** [`../specs/scenario-3-sharded.md`](../specs/scenario-3-sharded.md)
  (inherits [`../specs/common-experiment-setup.md`](../specs/common-experiment-setup.md)).
- **Workflow reference:** [`../../workflow/README.md`](../../workflow/README.md).
- **Reference test environment / shared troubleshooting:** the Scenario 1 runbook
  ([`scenario-1.md`](scenario-1.md)) — S3 uses **two** of the same Nebius L40S VMs.
- **Verification evidence:** [`../evidence/scenario-3/`](../evidence/scenario-3/).

## 1. Prerequisites

Same as [Scenario 1 §1](scenario-1.md#1-prerequisites) except **two** GPU nodes are required
(each an L40S-class 48 GB VM, no pre-installed NVIDIA driver needed — see
[Scenario 1 §2.1](scenario-1.md#21-reference-test-environment-known-good)), and a
**low-latency, high-bandwidth interconnect between the two nodes is strongly recommended** —
cross-node tensor parallelism is communication-intensive, and TTFT/throughput are directly
sensitive to inter-node latency (see §6). `NODE_ENDPOINTS` lists both, comma-separated:

```
NODE_ENDPOINTS="10.0.0.26:22,10.0.0.27:22"
```

`HF_TOKEN`, `SSH_USERNAME`, the SSH key, and `RUN_ID` are as for S1.

## 2. Infrastructure configuration

Two nodes become one self-contained k0s cluster (`bench-s3`, control plane co-located on the first).
Topology is fixed by [`workflow/config/scenario-s3.env`](../../workflow/config/scenario-s3.env):

| Setting | Value | Meaning |
|---|---|---|
| `EXPECTED_NODE_COUNT` | 2 | two provided nodes |
| `REPLICAS` | 2 | two pods forming **one** LeaderWorkerSet group |
| `GPU_COUNT_PER_REPLICA` | 1 | one GPU per pod |
| `NODES_PER_REPLICA` | 2 | both pods together serve **one** sharded model copy → **TP = 2** |

`GPU_MEMORY_UTILIZATION=0.85` comes from `workflow/config/common.env` (shared across S1/S2/S3, not
set in `scenario-s3.env` itself) — TP=2 needs this headroom for CUDA-graph capture once cross-node
NCCL/all-reduce buffers are added; a higher value reliably OOMs both shards during capture. Using
the same value across all three scenarios also keeps `DCGM_FI_DEV_FB_USED` comparable between them.

The leader (worker-index 0) runs the API server and exposes `/metrics`; the worker joins over NCCL
and serves no traffic directly. With one GPU per node, the two pods cannot land on the same node
regardless of the chart's own topology-spread preference — the GPU request itself forces one shard
per node, the same mechanism [Scenario 2](scenario-2-replicated.md#7-known-limitations) relies on
for one-replica-per-node. Shared defaults (`WORKSPACE_CPU=2`, `GPU_VENDOR=NVIDIA`, …) are in
`common.env`, same as S1/S2.

## 3. Execution steps

```bash
cd workflow
make build
make s3 RUN_ID=s3-run-1          # or: make docker-run SCENARIO=s3 RUN_ID=s3-run-1
```

Preset inputs for CI (note the two endpoints):

```bash
export HF_TOKEN=hf_xxx NODE_ENDPOINTS="10.0.0.26:22,10.0.0.27:22" SSH_USERNAME=ubuntu
make docker-run SCENARIO=s3 RUN_ID=s3-run-1 SSH_KEY_PATH=~/.ssh/bench
```

Phases and `RUN_FLAGS` variants are identical to [Scenario 1 §3](scenario-1.md#3-execution-steps).
The execute phase waits for the single leader pod to be Ready, then for the endpoint-picker to
report it discovered (`inference_pool_ready_pods`) — same gates as S1/S2, with `expected=1` model
copy — before sending load.

## 4. Expected outputs

The artifact layout and the collect-phase metric gate are the same as
[Scenario 1 §4](scenario-1.md#4-expected-outputs). A passing run additionally shows **two** pods
(the leader + worker) on distinct nodes, each holding roughly half the model weights.
`run-report.md` reports the aggregate aiperf performance.

## 5. Result interpretation

- **Functional acceptance** (gated): all phases `ok`, functional probe `pass`, aiperf 0 errors,
  0 missing metric series, `WorkspaceDeployment` Ready/Available `True`, the single model copy
  received load traffic (A2.2-equivalent, `expected=1`), pod placement OK (A3.1), cleanup tears
  down the k0s cluster on both nodes.
- **Scenario-3 acceptance** (spec §5):
  - **A3.1** exactly one logical model copy realised as two pods (leader + worker), one per node —
    gated in the collect phase: no two model-server pods share a node, recorded in
    `results/pod-placement.txt` (same mechanism as S2's A2.1) — spot-check with
    `kubectl -n ws-s3-sharded get pod -o wide`.
  - **A3.2** both GPUs used — `DCGM_FI_DEV_FB_USED` non-zero on both nodes (**40994 MiB**, both
    runs). This alone isn't proof of an actual split rather than a full copy on each node: S1 and S3
    share the same `GPU_MEMORY_UTILIZATION=0.85` (§2), yet S3's per-node figure (40994 MiB) is
    slightly *higher* than S1's full-copy figure (39098 MiB), not half of it, confirming
    `DCGM_FI_DEV_FB_USED` mostly reflects vLLM's configured reservation cap rather than the actual
    weight footprint — it wouldn't drop even if the split were fake. The real sharding proof is
    A3.1 (leader + worker on distinct single-GPU nodes) plus A3.3 below.
  - **A3.3** functional-probe completion is coherent and consistent with S1 for the deterministic
    prompt (same model + weights) — verified: the response's own `system_fingerprint`
    (`vllm-0.26.0-tp2-...`) confirms the engine genuinely initialized with tensor-parallel size 2.
  - **A3.4** the load probe completes with **0 errors** despite the cross-node path; TTFT is
    recorded and compared to the S1 baseline (reported, not gated).
- **Baseline** (`Qwen/Qwen3-8B`, concurrency 16, 200 requests): both runs passed every functional
  gate — run-1 61.18 tok/s, run-2 62.50 tok/s (within ~2.2%), TTFT p50 ~11.4–11.5 s. Markedly
  **slower** than S1's baseline (~520.9 tok/s, TTFT p50 ~0.40 s, ~0.12× S1's throughput) — expected
  cross-node communication overhead for a model that doesn't need sharding: each decode step pays a
  roughly fixed cross-node synchronization cost that dominates once per-GPU compute is this fast.
  S1 and S3 run at the same `GPU_MEMORY_UTILIZATION=0.85` (§2), so this gap isn't confounded by
  differing KV-cache capacity between them; these figures reflect the S3 configuration as a whole,
  not an isolated overhead measurement (§6). Full per-run data:
  [`../evidence/scenario-3/`](../evidence/scenario-3/).

## 6. Known limitations

See [spec §7](../specs/scenario-3-sharded.md#7-known-limitations): interconnect-bound (cross-node
TP adds significant latency — S3 is slower than S1/S2 on the same model, which is the point of the
scenario); sharding is demonstrative at the default 8B size (a larger `MODEL_ID` would make it
necessary); fault tolerance is weaker than S2 (losing either node's shard takes down the whole
model copy); placement is a preference backed by GPU scarcity, same as S2 — A3.1's placement gate
would still catch and fail the run if this ever didn't hold.

## 7. Troubleshooting

The shared failure modes (GPU not requested, driver < 580, missing metrics, StorageClass, header,
inotify, aiperf timeout, NGC pull) are in [Scenario 1 §7](scenario-1.md#7-troubleshooting).
Scenario-3-specific:

| Symptom | Cause | Fix |
|---|---|---|
| Both shard pods `CUDA out of memory` during CUDA-graph capture, whole LeaderWorkerSet group recreated repeatedly (pod-level `RESTARTS` may stay at 0 — the LWS controller recreates the group rather than restarting a single container) | `GPU_MEMORY_UTILIZATION` too high for TP=2 (no headroom left for NCCL/all-reduce buffers on top of the KV-cache reservation) | already defaulted to 0.85 in `common.env`; lower further (e.g. 0.75) via an environment override if it still OOMs on a smaller GPU |
| Only one shard pod scheduled (other Pending) | second node not joined, or its GPU not schedulable | check both nodes `Ready` (`bootstrap.log`) and both advertise `nvidia.com/gpu` (GPU operator ready on both) |
| Collect phase dies "pod-placement acceptance not met" (A3.1 fails) | both shard pods landed on the same node — spread is `ScheduleAnyway` (a preference), only expected if a node lacks a free GPU | check `results/pod-placement.txt`; with 1 GPU/node the GPU request should force one per node — investigate why it didn't |
| Execute phase dies "EPP never reported N ready pool endpoint(s)" | the endpoint-picker hasn't discovered the leader yet | check `inference_pool_ready_pods` is scraped; raise `EPP_READY_CHECK_TIMEOUT` (default 180s) only if this is consistently a slow-converge race |
| Workspace-ready timing out | cross-node NCCL rendezvous slow to converge | raise `TIMEOUT_WORKSPACE` (default 1500s); the functional probe's own retry loop already absorbs a leader that's Ready but not yet actually serving |

More knobs and rationale are documented inline in
[`workflow/config/common.env`](../../workflow/config/common.env) and
[`workflow/config/scenario-s3.env`](../../workflow/config/scenario-s3.env).

## 8. Reproduction

Same as [Scenario 1 §8](scenario-1.md#8-reproduction) with `SCENARIO=s3` and a two-node
`NODE_ENDPOINTS`; artifacts are sanitized in place at cleanup:

```bash
cd workflow
make build
export HF_TOKEN=hf_xxx NODE_ENDPOINTS="10.0.0.26:22,10.0.0.27:22" SSH_USERNAME=ubuntu
make docker-verify SCENARIO=s3 COUNT=2 SSH_KEY_PATH=~/.ssh/bench   # s3-run-1 then s3-run-2
./bin/package-evidence.sh s3 s3-run-1 s3-run-2                     # -> docs/evidence/scenario-3.tar.gz
```
