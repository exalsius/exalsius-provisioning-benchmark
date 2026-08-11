# Scenario 3 — Sharded inference (T1.3)

> **Inherits:** [Common Experiment Specification](common-experiment-setup.md).
> Only the deltas relative to the common spec are stated here.
> **Status:** Draft (design-only). Builds on the Scenario 1 reference implementation.

The **same** medium-sized LLM as S1/S2, served by a **single logical replica whose weights are
tensor-parallel-split across two nodes** (`multinode: true`, `tensorParallelism: 2`). Unlike S2,
no node holds a full copy — each node holds one shard and they serve requests cooperatively over
the cluster network. Demonstrates the **cross-node model sharding** path.

---

## 1. Target infrastructure (delta)

| Item | Value |
|------|-------|
| Nodes | **2** NVIDIA nodes, each with a single L40 (48 GB) GPU; **low-latency, high-bandwidth interconnect between nodes strongly recommended** (tensor parallelism is communication-intensive). |
| Cluster | Two-node k0s cluster on the provided nodes (`bench-s3`); control plane co-located on one node. |
| Model | `MODEL_ID`. Default `Qwen/Qwen3-8B` demonstrates the sharding path; set `MODEL_ID=Qwen/Qwen3-32B` (or larger) to make sharding **necessary** rather than demonstrative — see §7. |

## 2. Deployment configuration (delta)

| Concept | `WorkspaceDeployment` field | Value |
|---------|-----------------------------|-------|
| Decode replicas | `spec.values.decode.replicas` | **1** (one logical replica) |
| Tensor parallelism | `spec.values.tensorParallelism` | **2** (split across the two nodes) |
| Multi-node | `spec.values.multinode` | **`true`** |
| GPUs per replica | `spec.resources.perReplica.gpuCount` | **2** (1 per node) |

**Deploy manifests (reference, open-source self-contained path — no `exls`):**

Phases 1–2 are the common flow: `k0sctl` bootstraps a **two-node** k0s cluster on the provided
nodes, it is adopted as `ClusterDeployment/bench-s3`, and the GPU operator + monitoring are
installed by direct `helm install` (the `llm-d-stack` prereq is handled by the operator).
Phase 3 applies the WorkspaceDeployment below into that same cluster.

```yaml
# Phase 3 — deploy a single replica sharded (tensor-parallel) across both nodes.
apiVersion: workspaces.exalsius.ai/v1
kind: WorkspaceDeployment
metadata:
  name: s3-sharded
  namespace: kcm-system
spec:
  workspaceClassRef: llm-inference
  clusterDeploymentRef:
    name: bench-s3
    namespace: kcm-system
  resources:
    perReplica:
      gpuCount: 2          # 2 GPUs for the single replica = 1 per node (cross-node)
  values:
    huggingfaceToken: "${HF_TOKEN}"
    modelName: "${MODEL_ID}"
    multinode: true        # enable the llm-d cross-node inference path
    tensorParallelism: 2   # split weights across the two nodes
    decode:
      replicas: 1
```

The T2 workflow pins the exact chart value keys (`multinode`, `tensorParallelism`) and ensures
the two shard workers are placed **one per node** (anti-affinity), abstracting this behind
`MULTINODE` + `TENSOR_PARALLELISM`.

## 3. Expected outcome

- k0s comes up on both nodes and is adopted as `ClusterDeployment/bench-s3` (`Ready`); workspace `s3-sharded` ready.
- **One** logical decode replica realised as **two shard workers**, one per node; each GPU holds
  ~half the model weights.
- OpenAI-compatible endpoint returns a coherent completion — functionally identical output to
  S1 for the deterministic functional probe (same model, same weights, just partitioned).
- Load probe completes with 0 errors; latency reflects cross-node communication overhead
  (TTFT expected **higher** than the S1 baseline).

## 4. Required metrics (delta)

Common baseline **plus** scenario-specific:

| Metric | Purpose |
|--------|---------|
| Per-node GPU memory (`DCGM_FI_DEV_FB_USED` by node) | Confirm a genuine shard split: **each node holds only part** of the weights (materially less than S1's single-GPU footprint), not a full copy. |
| Per-node GPU utilisation (`DCGM_FI_DEV_GPU_UTIL`) | Both shards active on every request. |
| TTFT vs. S1 baseline (`vllm:time_to_first_token_seconds`) | Quantify cross-node communication overhead. |
| Inter-node traffic (node-exporter NIC bytes, if available) | Evidence of tensor-parallel all-reduce traffic between nodes. |

## 5. Acceptance criteria (delta)

Common criteria **plus**:

- **A3.1** Exactly **one** logical replica realised as **two shard workers**, one per node
  (`kubectl get pods -o wide` shows the two workers on distinct nodes).
- **A3.2** **Sharding verified:** each node's `DCGM_FI_DEV_FB_USED` is materially **less** than
  S1's single-GPU footprint (roughly half), showing the weights are split, not copied. The
  per-node figures are recorded; the split is confirmed qualitatively, not against a fixed ratio.
- **A3.3** Functional-probe completion is coherent and consistent with S1 for the deterministic
  prompt (same model + weights).
- **A3.4** The load probe completes with **0 errors** despite the cross-node path; TTFT is
  recorded and compared to the S1 baseline (reported, not gated).

## 6. Indicative timings (not acceptance gates)

Informational expectations — **not** pass/fail criteria (see [common spec §7](common-experiment-setup.md#7-acceptance-criteria-common)).

| Phase | Expected |
|-------|----------|
| Bootstrap + prepare cluster (Phases 1–2, 2 nodes: k0s + adopt + GPU/monitoring addons) | ~25 min |
| Workspace ready (multinode shard init) | ~25 min |
| Full run (Phase 0→6) | ~65 min |

## 7. Known limitations

- **Interconnect-bound:** without a fast node-to-node link, cross-node tensor parallelism adds
  significant latency; S3 is slower than S1/S2 on the same model. This is expected and is the
  point of the scenario.
- With the default 8B model, sharding is **demonstrative** (the model also fits one node). Raising
  `MODEL_ID` to a variant that exceeds single-GPU VRAM makes sharding *necessary*; the A3.2 split
  check validates the behaviour at any model size.
- Fault tolerance is weaker than S2: losing either node's shard takes down the single replica.
