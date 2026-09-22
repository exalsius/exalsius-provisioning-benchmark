# Scenario 3 — Sharded inference (T1.3)

> **Inherits:** [Common Experiment Specification](common-experiment-setup.md).
> Only the deltas relative to the common spec are stated here.
> **Status:** Implemented (as-built). Verified — two consecutive clean runs (T5.2). Builds on the
> Scenario 1 reference implementation. Operator runbook: [`../scenarios/scenario-3.md`](../scenarios/scenario-3.md).

The **same** medium-sized LLM as S1/S2, served by a **single logical model copy whose weights are
tensor-parallel-split across two nodes** — one LeaderWorkerSet group of size 2 (a leader and a
worker pod, one per node), cooperating over the cluster network via NCCL. Unlike S2, no node holds
a full copy — each node holds one shard. Demonstrates the **cross-node model-sharding** path.

---

## 1. Target infrastructure (delta)

| Item | Value |
|------|-------|
| Nodes | **2** NVIDIA nodes (L40S 48 GB reference), each with a single GPU; low-latency, high-bandwidth interconnect between nodes recommended (tensor parallelism is communication-intensive). |
| Cluster | Two-node k0s cluster on the provided nodes (`bench-s3`); control plane co-located on the first node. |
| Model | `MODEL_ID` (default `Qwen/Qwen3-8B`) — split across both GPUs. Fits one GPU already, so sharding here is demonstrative; set `MODEL_ID` to a variant that exceeds single-GPU VRAM to make it necessary — see §7. |

## 2. Deployment configuration (delta)

| Concept | `WorkspaceDeployment` field | Value |
|---------|-----------------------------|-------|
| Replicas (pods) | `spec.resources.replicas` | **2** (one LeaderWorkerSet group of size 2 — a leader + a worker) |
| GPUs per pod | `spec.resources.perReplica.gpuCount` | **1** |
| Pods per model copy | `spec.values.modelServer.nodesPerReplica` | **2** (both pods together serve ONE model, sharded) |
| ⇒ model copies | `replicas / nodesPerReplica` | **1** |
| ⇒ tensor-parallel size | `nodesPerReplica × gpuCount` | **2** |

Phases 1–2 are the common flow ([common spec §4](common-experiment-setup.md#4-end-to-end-execution-flow-common)):
`k0sctl` bootstraps a **two-node** k0s cluster on the provided nodes, adopted as
`ClusterDeployment/bench-s3`; OpenEBS + the GPU operator + KOF are installed by direct
`helm install`; the workspace catalog (`llm-d-model-1-0-0` + its `llm-d-infra-1-0-0` prereq) is
registered. Phase 3 applies the WorkspaceDeployment below.

```yaml
# Phase 3 — deploy ONE model copy tensor-parallel-sharded across both nodes.
apiVersion: workspaces.exalsius.ai/v1
kind: WorkspaceDeployment
metadata:
  name: s3-sharded
  namespace: kcm-system
spec:
  workspaceClassRef: llm-d-model-1-0-0
  clusterDeploymentRef:
    name: bench-s3            # the adopted self-hosted cluster
    namespace: kcm-system
  resources:
    replicas: 2                # two pods (leader + worker) forming ONE LeaderWorkerSet group
    perReplica:
      cpu: "2"                # well below the class default (8) to fit the co-located node
      gpuCount: 1
      gpuVendor: NVIDIA       # lets the operator inject gpuResourceName (nvidia.com/gpu)
  values:
    huggingfaceToken: "${HF_TOKEN}"
    model:
      name: "${MODEL_ID}"     # default Qwen/Qwen3-8B
    modelServer:
      nodesPerReplica: 2      # both pods together serve one sharded model copy (TP=2)
```

Only the leader (worker-index 0) runs the API server and exposes `/metrics`; the worker joins over
NCCL and serves no traffic directly (see
[`workflow/templates/vllm-podmonitor.yaml.tmpl`](../../workflow/templates/vllm-podmonitor.yaml.tmpl)).
With one GPU per node, the leader and worker cannot be scheduled onto the same node regardless of
the chart's own topology-spread preference — the GPU request itself forces one shard per node on
the reference environment, the same mechanism
[Scenario 2](scenario-2-replicated.md#7-known-limitations) relies on for one-replica-per-node.

## 3. Expected outcome

- k0s comes up on both nodes and is adopted as `ClusterDeployment/bench-s3` (`Ready`); workspace
  `s3-sharded` reaches ready (see [common spec §7.1](common-experiment-setup.md#7-acceptance-criteria-common)
  for what "ready" is actually gated on — namespace-presence for sequencing, the CR condition
  checked later as a hard gate).
- **One** logical model copy realised as a leader + worker pod pair, one per node; each GPU holds
  roughly half the model weights (tensor-parallel split).
- OpenAI-compatible endpoint returns a coherent completion — functionally identical output to S1
  for the deterministic functional probe (same model, same weights, just partitioned).
- Load probe completes with 0 errors; latency reflects cross-node communication overhead (TTFT
  expected **higher** than the S1 baseline — reported, not gated).

## 4. Required metrics (delta)

Common baseline (§6 of the common spec) **plus** scenario-specific, read per node from the metric
snapshots:

| Metric | Purpose |
|--------|---------|
| Per-node GPU memory (`DCGM_FI_DEV_FB_USED` by `Hostname`) | Confirms both GPUs are in use. Not a shard-split proof on its own — see A3.2. |
| Per-node GPU utilisation (`DCGM_FI_DEV_GPU_UTIL`) | Both shards active while serving. |
| TTFT vs. S1 baseline (`vllm:time_to_first_token_seconds_count`) | Recorded for comparison (reported, not gated) — reflects the S3 configuration as a whole (cross-node communication plus the lower `GPU_MEMORY_UTILIZATION`), not an isolated measurement of communication overhead. |

## 5. Acceptance criteria (delta)

Common criteria (§7) **plus**:

- **A3.1** Exactly **one** logical model copy realised as **two** pods (a LeaderWorkerSet leader +
  worker), one per node (`kubectl -n ws-s3-sharded get pod -o wide` shows two, on distinct nodes) —
  confirmed by manual inspection, like S2's A2.1.
- **A3.2** **Both GPUs used:** each node's `DCGM_FI_DEV_FB_USED` is non-zero. This alone does not
  prove a genuine split rather than a full copy on each node — S3 needs a lower
  `GPU_MEMORY_UTILIZATION` than S1 (§2 note; the CUDA-graph-capture OOM under TP=2 otherwise),
  so vLLM's memory-reservation sizing differs between the two scenarios and their raw
  `DCGM_FI_DEV_FB_USED` figures are not directly comparable as a ratio. The actual sharding proof
  is **A3.1** (leader + worker scheduled on two distinct single-GPU nodes) combined with **A3.3**'s
  `system_fingerprint` check below.
- **A3.3** Functional-probe completion is coherent and consistent with S1 for the deterministic
  prompt (same model + weights); the response's own `system_fingerprint` reports `tp2`, confirming
  the engine genuinely initialized with tensor-parallel size 2 rather than two independent copies.
- **A3.4** The load probe completes with **0 errors** despite the cross-node path; TTFT is
  recorded and compared to the S1 baseline (reported, not gated).

## 6. Indicative timings (not acceptance gates)

Informational expectations — **not** pass/fail criteria (see [common spec §7](common-experiment-setup.md#7-acceptance-criteria-common)).

| Phase | Expected |
|-------|----------|
| Bootstrap + prepare cluster (Phases 1–2, 2 nodes) | ~25 min |
| Workspace ready (cross-node shard init + NCCL rendezvous) | ~15–25 min |
| Full run (Phase 0→6) | ~60–70 min |

## 7. Known limitations

- **Interconnect-bound:** without a fast node-to-node link, cross-node tensor parallelism adds
  significant latency; S3 is slower than S1/S2 on the same model. This is expected and is the
  point of the scenario.
- With the default 8B model, sharding is **demonstrative** (the model also fits one node). Raising
  `MODEL_ID` to a variant that exceeds single-GPU VRAM makes sharding *necessary*; the A3.2 split
  check validates the behaviour at any model size.
- Fault tolerance is weaker than S2: losing either node's shard takes down the single model copy.
- Placement is a *preference* (the chart's own topology-spread, if any — not configured by this
  repo), not a guarantee; with one GPU per node the GPU request forces one shard per node anyway,
  same as [Scenario 2](scenario-2-replicated.md#7-known-limitations).
- **Workspace-ready timing:** if cross-node NCCL rendezvous is slow to converge, raise
  `TIMEOUT_WORKSPACE` (default 1500s, `workflow/config/common.env`); the functional probe's own
  retry loop (`TIMEOUT_FUNCPROBE`, 15s-interval retries) already absorbs a leader that reports
  Ready before it can actually serve, so this is a tuning knob, not something that needs a code
  change.
