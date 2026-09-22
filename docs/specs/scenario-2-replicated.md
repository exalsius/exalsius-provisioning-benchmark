# Scenario 2 — Replicated inference (T1.2)

> **Inherits:** [Common Experiment Specification](common-experiment-setup.md).
> Only the deltas relative to the common spec are stated here.
> **Status:** Implemented (as-built). Verified — two consecutive clean runs (T4.2). Builds on
> the Scenario 1 reference implementation. Operator runbook: [`../scenarios/scenario-2.md`](../scenarios/scenario-2.md).

The **same** medium-sized LLM as S1, served by **two independent model-server pods** — one per
node — behind the shared llm-d router. Each pod holds a full copy of the model; the router's
endpoint-picker load-balances requests across them. Demonstrates **horizontal scaling and
availability** (not model sharding).

---

## 1. Target infrastructure (delta)

| Item | Value |
|------|-------|
| Nodes | **2** NVIDIA nodes (L40S 48 GB reference), each fitting a full model copy. |
| Cluster | Two-node k0s cluster on the provided nodes (`bench-s2`); control plane co-located on the first node. |
| Model | `MODEL_ID` (default `Qwen/Qwen3-8B`) — a full copy per node. |

## 2. Deployment configuration (delta)

| Concept | `WorkspaceDeployment` field | Value |
|---------|-----------------------------|-------|
| Replicas (pods) | `spec.resources.replicas` | **2** (one whole model per pod) |
| GPUs per pod | `spec.resources.perReplica.gpuCount` | **1** |
| Pods per model copy | `spec.values.modelServer.nodesPerReplica` | **1** |
| ⇒ model copies | `replicas / nodesPerReplica` | **2** |
| ⇒ tensor-parallel size | `nodesPerReplica × gpuCount` | **1** |

Phases 1–2 are the common flow: `k0sctl` bootstraps a **two-node** k0s cluster (one
controller+worker, one worker), adopted as `ClusterDeployment/bench-s2`; OpenEBS + GPU operator +
KOF are installed by direct `helm install`; the workspace catalog (`llm-d-model-1-0-0` + its
`llm-d-infra-1-0-0` prereq) is registered. Phase 3 applies the WorkspaceDeployment below.

```yaml
# Phase 3 — deploy the llm-d-model workspace with TWO independent replicas.
apiVersion: workspaces.exalsius.ai/v1
kind: WorkspaceDeployment
metadata:
  name: s2-replicated
  namespace: kcm-system
spec:
  workspaceClassRef: llm-d-model-1-0-0
  clusterDeploymentRef:
    name: bench-s2
    namespace: kcm-system
  resources:
    replicas: 2              # two pods; the topology-spread constraint places one per node
    perReplica:
      cpu: "2"
      gpuCount: 1
      gpuVendor: NVIDIA      # operator injects gpuResourceName (nvidia.com/gpu)
  values:
    huggingfaceToken: "${HF_TOKEN}"
    model:
      name: "${MODEL_ID}"
    modelServer:
      nodesPerReplica: 1     # each pod is a whole model (no sharding)
```

Both pods are LeaderWorkerSet leaders (each a group of size 1); the `spread` constraint prefers one
per node. The router's `InferencePool` selects both, so the endpoint-picker balances across them.

## 3. Expected outcome

- k0s comes up on both nodes and is adopted as `ClusterDeployment/bench-s2` (`Ready`); workspace `s2-replicated` ready.
- **Two** serving pods, one per node, each loading a full model copy.
- The endpoint-picker distributes the aiperf load across both replicas.
- Aggregate throughput is **expected to exceed the S1 baseline** (horizontal scaling); the figure is
  recorded and reported, not gated.

## 4. Required metrics (delta)

Common baseline (§6 of the common spec) **plus** scenario-specific — all from the same series, read
per pod/node from the metric snapshots:

| Metric | Purpose |
|--------|---------|
| Per-replica request counts (`vllm:num_requests_running` by pod) | Verify the endpoint-picker **balances** load across both replicas. |
| Per-node GPU footprint (`DCGM_FI_DEV_FB_USED` by `Hostname`) | Both GPUs active; each holds a full model copy. |
| Aggregate vs. per-replica throughput (`vllm:generation_tokens_total` summed vs. by pod) | Quantify scaling relative to S1. |

## 5. Acceptance criteria (delta)

Common criteria (§7) **plus**:

- **A2.1** Exactly **two** serving model-server pods running (LWS leaders), one per node — gated
  in the collect phase (common spec §7.1): no two model-server pods share a `.spec.nodeName`,
  recorded in `results/pod-placement.txt`.
- **A2.2** Both replicas receive traffic **during the aiperf window specifically**, verified by a
  per-pod delta of `vllm:generation_tokens_total` (value immediately before aiperf launches vs. the
  post-run snapshot) rather than the raw cumulative counter — which is polluted by whatever the
  functional probe already sent to a single pod before aiperf started — or the instantaneous
  `num_requests_running` gauge, which can read 0 right after the run finishes regardless of whether
  load was balanced. Both deltas must be positive.
- **A2.3** Both GPUs report non-zero `DCGM_FI_DEV_FB_USED` (a full model copy on each node).
- **A2.4** Aggregate and per-replica throughput are recorded and compared to the S1 baseline
  (expected to exceed it). Reported, not gated.

## 6. Indicative timings (not acceptance gates)

Informational expectations — **not** pass/fail criteria (see [common spec §7](common-experiment-setup.md#7-acceptance-criteria-common)).

| Phase | Expected |
|-------|----------|
| Bootstrap + prepare cluster (Phases 1–2, 2 nodes) | ~25 min |
| Workspace ready (2 replicas, parallel model pull) | ~15 min |
| Full run (Phase 0→6) | ~55–65 min |

## 7. Known limitations

- Each replica must independently fit the full model — replication does **not** enable larger
  models (that is Scenario 3's sharding).
- Placement is a *preference* (`ScheduleAnyway` topology spread), not a guarantee; with one GPU per
  node the per-pod GPU request effectively forces one pod per node anyway. A2.1's placement gate
  (common spec §7.1) would still catch and fail the run if this ever didn't hold.
- Scaling is sub-linear (shared gateway/endpoint-picker); the speed-up over S1 depends on load and
  is reported descriptively. The load must sustain enough concurrency to keep both replicas busy.
