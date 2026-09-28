# Benchmark Specifications (T1)

Common experiment specification and the three scenario specifications for the WP3 Exalsius
provisioning and experimentation benchmark. Originally **design-only** T1 deliverables; the
**common spec and all three scenarios have been updated to as-built** (T3/T4/T5). Operator
runbooks: [Scenario 1](../scenarios/scenario-1.md), [Scenario 2](../scenarios/scenario-2.md),
[Scenario 3](../scenarios/scenario-3.md).

> **Open-source-only, self-contained.** Everything is built on public Exalsius / OSS components —
> `exalsius-operator` (`WorkspaceClass`, `WorkspaceDeployment` CRDs), `k0rdent`/KCM
> (adopted `ClusterDeployment`), `exalsius-workspace-hub` (the `llm-d-model-1-0-0` chart, workspace-hub
> 1.0.0), k0rdent **KOF** (VictoriaMetrics + OpenTelemetry + Grafana, the latter wired up by this
> repo's own `Grafana`/`GrafanaDatasource` CRs and dashboard), the NVIDIA GPU operator, and OpenEBS —
> driven by `k0sctl`/`kubectl`/`helm` and tailored scripting. The `exls` CLI and the **closed-source
> Exalsius SaaS API** are **not used** (the VictoriaMetrics here is the OSS KOF one, not the SaaS
> offering).
>
> **One cluster per run (mgmt == target).** `k0sctl` bootstraps a k0s cluster directly on the
> provided SSH nodes; it is prepared in place (OpenEBS + GPU operator + KOF via direct `helm
> install`, then k0rdent + operator + cluster adoption), runs the scenario workload, and is
> destroyed with `k0sctl reset` at cleanup.

| Spec | Task | Summary |
|------|------|---------|
| [Common Experiment Setup](common-experiment-setup.md) | T1 | Shared infrastructure assumptions, deployment conventions, end-to-end flow, expected outputs, required metrics, and acceptance criteria inherited by every scenario. **As-built.** |
| [Scenario 1 — Single-node](scenario-1-single-node.md) | T1.1 / T3 | Medium LLM, one pod, one NVIDIA node. Reference baseline. **Implemented.** |
| [Scenario 2 — Replicated](scenario-2-replicated.md) | T1.2 / T4 | Same model, two replicas across two nodes — horizontal scaling / availability. **Implemented; verified (T4).** |
| [Scenario 3 — Sharded](scenario-3-sharded.md) | T1.3 / T5 | Same model, one model sharded across two nodes — cross-node sharding. **Implemented; verified (T5).** |
| [Telemetry Specification](telemetry.md) | T6.1 | Per-metric source, unit, labels, granularity, and interpretation for every collected series (vLLM, DCGM, EPP) across all three scenarios. **Draft.** |

## Reading order

1. Start with the **Common Experiment Setup** — the scenario specs only state deltas against it.
2. Read the scenario spec(s) you intend to run.
3. See the **Telemetry Specification** for the full detail behind each spec's "Required metrics"
   section.

## Scenario matrix (at a glance)

Topology in as-built terms: `tensor-parallel size = NODES_PER_REPLICA × GPU_COUNT_PER_REPLICA`,
`model copies = REPLICAS / NODES_PER_REPLICA`.

| | Nodes | Replicas (pods) | GPUs/pod | Nodes/copy | TP | Model copies |
|--|:--:|:--:|:--:|:--:|:--:|:--:|
| **S1 Single-node** | 1 | 1 | 1 | 1 | 1 | 1 (full) |
| **S2 Replicated** | 2 | 2 | 1 | 1 | 1 | 2 (full, one/node) |
| **S3 Sharded** | 2 | 2 | 1 | 2 | 2 | 1 (split across nodes) |

All three serve the **same** medium model (`MODEL_ID`, default `Qwen/Qwen3-8B`); only the
deployment topology differs.
