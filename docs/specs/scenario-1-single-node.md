# Scenario 1 — Single-node inference (T1.1)

> **Inherits:** [Common Experiment Specification](common-experiment-setup.md).
> Only the deltas relative to the common spec are stated here.
> **Status:** Draft (design-only). Acts as the **reference implementation** for T3.

A medium-sized LLM served by a single vLLM replica on **one** NVIDIA node. This is the
baseline against which the replicated (S2) and sharded (S3) scenarios are compared.

---

## 1. Target infrastructure (delta)

| Item | Value |
|------|-------|
| Nodes | **1** NVIDIA node (`IP:Port`) with a single L40 (48 GB) GPU. |
| Cluster | Single-node k0s cluster on that node (`bench-s1`), control plane co-located with the workload. |
| Model | `MODEL_ID` (default `Qwen/Qwen3-8B`) — must fit on the single GPU. |

## 2. Deployment configuration (delta)

| Concept | `WorkspaceDeployment` field | Value |
|---------|-----------------------------|-------|
| Decode replicas | `spec.values.decode.replicas` | **1** |
| Tensor parallelism | `spec.values.tensorParallelism` | **1** |
| Multi-node | `spec.values.multinode` | `false` |
| GPUs per replica | `spec.resources.perReplica.gpuCount` | **1** |

**Deploy manifests (reference, open-source self-contained path — no `exls`):**

Phases 1–2 are the common flow ([common spec §4](common-experiment-setup.md#4-end-to-end-execution-flow-common)):
`k0sctl` bootstraps a **single-node** k0s cluster on the one provided node, it is adopted into
k0rdent as `ClusterDeployment/bench-s1`, and the GPU operator + monitoring are installed by
direct `helm install` (the `llm-d-stack` prereq is handled by the operator). Phase 3 then
applies the WorkspaceDeployment below into that same cluster.

```yaml
# Phase 3 — deploy the single-replica llm-inference workspace into the adopted cluster.
apiVersion: workspaces.exalsius.ai/v1
kind: WorkspaceDeployment
metadata:
  name: s1-single-node
  namespace: kcm-system
spec:
  workspaceClassRef: llm-inference
  clusterDeploymentRef:
    name: bench-s1            # the adopted self-hosted cluster
    namespace: kcm-system
  resources:
    perReplica:
      gpuCount: 1
  values:
    huggingfaceToken: "${HF_TOKEN}"
    modelName: "${MODEL_ID}"      # default Qwen/Qwen3-8B
    # decode.replicas: 1, tensorParallelism: 1, multinode: false are the class defaults
```

```bash
# Applied by the T2 workflow (Phase 3):
kubectl apply -f workspacedeployment-s1.yaml
kubectl wait --for=condition=Available workspacedeployment/s1-single-node -n kcm-system --timeout=15m
```

## 3. Expected outcome

- k0s comes up on the node and is adopted as `ClusterDeployment/bench-s1` (`Ready`); workspace `s1-single-node` reaches ready.
- One vLLM decode pod scheduled on the single node; the model loads into that GPU.
- OpenAI-compatible endpoint answers the functional probe with a coherent completion.
- Load probe (200 requests, concurrency 16) completes with 0 errors and yields a **baseline**
  throughput/latency profile that S2 and S3 are measured against.

## 4. Required metrics (delta)

Common baseline (§6 of the common spec) **plus** scenario-specific:

| Metric | Purpose |
|--------|---------|
| GPU memory used on the single GPU (`DCGM_FI_DEV_FB_USED`) | Confirms the model fits one GPU and establishes the memory baseline. |
| Single-replica TTFT & throughput (`vllm:time_to_first_token_seconds`, `vllm:generation_tokens_total`) | Baseline latency/throughput for cross-scenario comparison. |

## 5. Acceptance criteria (delta)

Common criteria (§7) **plus**:

- **A1.1** Exactly **one** vLLM decode replica is running (`vllm:num_requests_running` reported
  by a single pod; `kubectl get pods` shows one decode pod).
- **A1.2** Model resident on a single GPU: `DCGM_FI_DEV_FB_USED` is non-zero on exactly one GPU.
- **A1.3** Baseline metrics recorded and stored so S2/S3 comparisons are possible.

## 6. Indicative timings (not acceptance gates)

Informational expectations for spotting regressions and sizing CI — **not** pass/fail criteria
(see [common spec §7](common-experiment-setup.md#7-acceptance-criteria-common)).

| Phase | Expected |
|-------|----------|
| Bootstrap + prepare cluster (Phases 1–2: k0s + adopt + GPU/monitoring addons) | ~20 min |
| Workspace ready incl. model pull (Phase 3) | ~15 min |
| Full run (Phase 0→6) | ~50 min |

## 7. Known limitations

- No redundancy: a single replica means no availability guarantee (contrast S2).
- Throughput is bounded by one GPU; not intended to demonstrate scaling.
- Timings assume a warm image cache; the first run pulls images + weights and takes longer.
