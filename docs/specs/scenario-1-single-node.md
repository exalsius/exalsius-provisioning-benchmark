# Scenario 1 — Single-node inference (T1.1)

> **Inherits:** [Common Experiment Specification](common-experiment-setup.md).
> Only the deltas relative to the common spec are stated here.
> **Status:** Implemented (as-built). Acts as the **reference implementation** for T3. See the
> operator runbook: [`../scenarios/scenario-1.md`](../scenarios/scenario-1.md).

A medium-sized LLM served by a single vLLM model-server pod on **one** NVIDIA node. This is the
baseline against which the replicated (S2) and sharded (S3) scenarios are compared.

---

## 1. Target infrastructure (delta)

| Item | Value |
|------|-------|
| Nodes | **1** NVIDIA node (`IP:Port`) with a single GPU (L40 48 GB reference; H100 validated), driver ≥ 580. |
| Cluster | Single-node k0s cluster on that node (`bench-s1`), control plane co-located with the workload. |
| Model | `MODEL_ID` (default `Qwen/Qwen3-8B`) — must fit on the single GPU. |

## 2. Deployment configuration (delta)

| Concept | `WorkspaceDeployment` field | Value |
|---------|-----------------------------|-------|
| Replicas (pods) | `spec.resources.replicas` | **1** |
| GPUs per pod | `spec.resources.perReplica.gpuCount` | **1** |
| Pods per model copy | `spec.values.modelServer.nodesPerReplica` | **1** |
| ⇒ tensor-parallel size | `nodesPerReplica × gpuCount` | **1** |

**Deploy manifest (reference, OSS self-contained path — no `exls`):**

Phases 1–2 are the common flow ([common spec §4](common-experiment-setup.md#4-end-to-end-execution-flow-common)):
`k0sctl` bootstraps a **single-node** k0s cluster on the one provided node, it is adopted into
k0rdent as `ClusterDeployment/bench-s1`, and OpenEBS + the GPU operator + KOF are installed by
direct `helm install`. The workspace catalog (`llm-d-model-1-0-0` + its `llm-d-infra-1-0-0` prereq)
is registered; Phase 3 then applies the WorkspaceDeployment below.

```yaml
# Phase 3 — deploy the single-pod llm-d-model workspace into the adopted cluster.
apiVersion: workspaces.exalsius.ai/v1
kind: WorkspaceDeployment
metadata:
  name: s1-single-node
  namespace: kcm-system
spec:
  workspaceClassRef: llm-d-model-1-0-0
  clusterDeploymentRef:
    name: bench-s1            # the adopted self-hosted cluster
    namespace: kcm-system
  resources:
    replicas: 1
    perReplica:
      cpu: "2"               # well below the class default (8) to fit the co-located node
      gpuCount: 1
      gpuVendor: NVIDIA      # lets the operator inject gpuResourceName (nvidia.com/gpu)
  values:
    huggingfaceToken: "${HF_TOKEN}"
    model:
      name: "${MODEL_ID}"    # default Qwen/Qwen3-8B
    modelServer:
      nodesPerReplica: 1     # single-node
```

```bash
# Applied by the T2 workflow (Phase 3):
kubectl apply -f workspacedeployment-s1.yaml
# Gate on the model's workspace namespace appearing (ws-s1-single-node), not on the
# WorkspaceDeployment's own Available/Ready condition: that condition can report True
# while the shared llm-d-infra prerequisite (installed once per cluster) is still in
# progress, before the model's ServiceSet has been applied. The workflow polls (10s
# interval, full workspace timeout budget ~30m) rather than using `kubectl wait`:
until kubectl get namespace ws-s1-single-node >/dev/null 2>&1; do sleep 10; done
```

## 3. Expected outcome

- k0s comes up on the node and is adopted as `ClusterDeployment/bench-s1` (`Ready`); workspace `s1-single-node` reaches ready.
- One vLLM model-server pod (a LeaderWorkerSet leader) scheduled on the single node; the model loads into that GPU.
- OpenAI-compatible endpoint (shared agentgateway `:80`, `X-Gateway-Model-Name` header) answers the functional probe with a coherent completion.
- aiperf load probe (200 requests, concurrency 16) completes with 0 errors and yields a **baseline**
  throughput/latency profile that S2 and S3 are measured against.

## 4. Required metrics (delta)

Common baseline (§6 of the common spec) **plus** scenario-specific:

| Metric | Purpose |
|--------|---------|
| GPU memory used on the single GPU (`DCGM_FI_DEV_FB_USED`) | Confirms the model fits one GPU and establishes the memory baseline. |
| Single-replica TTFT & throughput (`vllm:time_to_first_token_seconds_count`, `vllm:generation_tokens_total`) | Baseline latency/throughput for cross-scenario comparison. |

## 5. Acceptance criteria (delta)

Common criteria (§7) **plus**:

- **A1.1** Exactly **one** vLLM model-server pod is running (`kubectl get pods -n ws-s1-single-node` shows one serving leader).
- **A1.2** Model resident on a single GPU: `DCGM_FI_DEV_FB_USED` is non-zero on exactly one GPU.
- **A1.3** Baseline metrics recorded and stored so S2/S3 comparisons are possible.

## 6. Indicative timings (not acceptance gates)

Informational expectations for spotting regressions and sizing CI — **not** pass/fail criteria
(see [common spec §7](common-experiment-setup.md#7-acceptance-criteria-common)).

| Phase | Expected |
|-------|----------|
| Bootstrap + prepare cluster (Phases 1–2: k0s + OpenEBS + GPU operator + KCM + KOF + adopt + catalog) | ~20–25 min |
| Workspace ready incl. model pull (Phase 3) | ~15 min |
| Full run (Phase 0→6) | ~50–60 min |

## 7. Known limitations

- No redundancy: a single pod means no availability guarantee (contrast S2).
- Throughput is bounded by one GPU; not intended to demonstrate scaling.
- Timings assume a warm image cache; the first run pulls images + weights and takes longer.
