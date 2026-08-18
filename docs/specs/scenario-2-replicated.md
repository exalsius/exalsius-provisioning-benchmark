# Scenario 2 — Replicated inference (T1.2)

> **Inherits:** [Common Experiment Specification](common-experiment-setup.md).
> Only the deltas relative to the common spec are stated here.
> **Status:** Draft (design-only). Builds on the Scenario 1 reference implementation.

The **same** medium-sized LLM as S1, served by **two independent decode replicas** — one per
node — behind the shared llm-d inference scheduler. Each replica holds a full copy of the model;
the scheduler load-balances requests across them. Demonstrates **horizontal scaling and
availability** (not model sharding).

---

## 1. Target infrastructure (delta)

| Item | Value |
|------|-------|
| Nodes | **2** NVIDIA nodes, each with a single L40 (48 GB) GPU (each must fit a full model copy). |
| Cluster | Two-node k0s cluster on the provided nodes (`bench-s2`); control plane co-located on one node. |
| Model | `MODEL_ID` (default `Qwen/Qwen3-8B`) — a full copy per node. |

## 2. Deployment configuration (delta)

| Concept | `WorkspaceDeployment` field | Value |
|---------|-----------------------------|-------|
| Decode replicas | `spec.values.decode.replicas` | **2** (one per node) |
| Tensor parallelism | `spec.values.tensorParallelism` | **1** (each replica on a single GPU) |
| Multi-node | `spec.values.multinode` | `false` |
| GPUs per replica | `spec.resources.perReplica.gpuCount` | **1** |

**Deploy manifests (reference, open-source self-contained path — no `exls`):**

Phases 1–2 are the common flow: `k0sctl` bootstraps a **two-node** k0s cluster on the provided
nodes (one controller+worker, one worker), it is adopted as `ClusterDeployment/bench-s2`, and
the GPU operator + monitoring are installed by direct `helm install` (the `llm-d-stack` prereq
is handled by the operator). Phase 3 applies the WorkspaceDeployment below into that same cluster.

```yaml
# Phase 3 — deploy the llm-inference workspace with TWO decode replicas.
apiVersion: workspaces.exalsius.ai/v1
kind: WorkspaceDeployment
metadata:
  name: s2-replicated
  namespace: kcm-system
spec:
  workspaceClassRef: llm-inference
  clusterDeploymentRef:
    name: bench-s2
    namespace: kcm-system
  resources:
    perReplica:
      gpuCount: 1
  values:
    huggingfaceToken: "${HF_TOKEN}"
    modelName: "${MODEL_ID}"
    decode:
      replicas: 2        # one full model copy per node, load-balanced by the llm-d scheduler
```

The exact chart value key for the decode replica count is pinned by the T2 workflow (abstracted
behind `DECODE_REPLICAS`).

## 3. Expected outcome

- k0s comes up on both nodes and is adopted as `ClusterDeployment/bench-s2` (`Ready`); workspace `s2-replicated` ready.
- **Two** vLLM decode pods, one scheduled per node, each loading a full model copy.
- The llm-d scheduler distributes the load probe across both replicas.
- Aggregate throughput is **expected to exceed the S1 baseline** (horizontal scaling); the actual
  figure is recorded and reported, not gated.

## 4. Required metrics (delta)

Common baseline **plus** scenario-specific:

| Metric | Purpose |
|--------|---------|
| Per-replica request counts (`vllm:num_requests_running` grouped by pod) | Verify the scheduler **balances** load across both replicas. |
| Per-node GPU utilisation & memory (`DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED` by node) | Both GPUs active; each holds a full model copy. |
| Aggregate vs. per-replica throughput (`vllm:generation_tokens_total` summed vs. by pod) | Quantify scaling relative to S1. |

## 5. Acceptance criteria (delta)

Common criteria **plus**:

- **A2.1** Exactly **two** vLLM decode replicas running, one per node.
- **A2.2** Both replicas receive traffic under load — neither replica's request share is 0%
  during the load probe (scheduler load-balancing verified).
- **A2.3** Both GPUs report non-zero `DCGM_FI_DEV_FB_USED` (a full model copy on each node).
- **A2.4** Aggregate and per-replica throughput are recorded and compared to the S1 baseline
  (expected to exceed it). Reported, not gated.

## 6. Indicative timings (not acceptance gates)

Informational expectations — **not** pass/fail criteria (see [common spec §7](common-experiment-setup.md#7-acceptance-criteria-common)).

| Phase | Expected |
|-------|----------|
| Bootstrap + prepare cluster (Phases 1–2, 2 nodes: k0s + adopt + GPU/monitoring addons) | ~25 min |
| Workspace ready (2 replicas, parallel model pull) | ~20 min |
| Full run (Phase 0→6) | ~60 min |

## 7. Known limitations

- Each replica must independently fit the full model — replication does **not** enable larger
  models (that is Scenario 3's sharding).
- Scaling is sub-linear due to scheduler overhead and shared ingress; the observed speed-up over
  S1 depends on load and is reported descriptively.
- Aggregate throughput depends on the load generator sustaining enough concurrency to keep both
  replicas busy; `CONCURRENCY` must exceed single-replica saturation.
