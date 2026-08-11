# Benchmark Specifications (T1)

Common experiment specification and the three scenario specifications for the WP3 Exalsius
provisioning and experimentation benchmark. These are **design-only** deliverables for **T1**;
implementation follows in T2–T6.

> **Open-source-only, self-contained.** Everything is built on the public Exalsius components —
> `exalsius-operator` (`WorkspaceClass`, `WorkspaceDeployment` CRDs), `k0rdent`/KCM
> (adopted `ClusterDeployment`), `exalsius-workspace-hub` (the `llm-inference` chart), and
> `exalsius-grafana-dashboards` — driven by `k0sctl`/`kubectl`/`helm` and tailored scripting.
> The `exls` CLI (itself open-source, but it drives the **closed-source Exalsius SaaS API**, so
> it is not usable in a self-hosted setup) and the SaaS observability are **not used**.
>
> **One cluster per run (mgmt == target).** `k0sctl` bootstraps a k0s cluster directly on the
> provided SSH nodes; it is prepared in place (GPU operator + monitoring via direct `helm
> install`, then k0rdent + operator + cluster adoption), runs the scenario workload, and is
> destroyed with `k0sctl reset` at cleanup.

| Spec | Task | Summary |
|------|------|---------|
| [Common Experiment Setup](common-experiment-setup.md) | T1 | Shared infrastructure assumptions, deployment conventions, end-to-end flow, expected outputs, required metrics, and acceptance criteria inherited by every scenario. |
| [Scenario 1 — Single-node](scenario-1-single-node.md) | T1.1 | Medium LLM, one replica, one NVIDIA node. Reference baseline. |
| [Scenario 2 — Replicated](scenario-2-replicated.md) | T1.2 | Same model, two replicas across two nodes — horizontal scaling / availability. |
| [Scenario 3 — Sharded](scenario-3-sharded.md) | T1.3 | Same model, one replica tensor-parallel-split across two nodes — cross-node sharding. |

## Reading order

1. Start with the **Common Experiment Setup** — the scenario specs only state deltas against it.
2. Read the scenario spec(s) you intend to run.

## Scenario matrix (at a glance)

| | Nodes | Decode replicas | Tensor parallelism | Multi-node | Model copies |
|--|:--:|:--:|:--:|:--:|:--:|
| **S1 Single-node** | 1 | 1 | 1 | false | 1 (full) |
| **S2 Replicated** | 2 | 2 | 1 | false | 2 (full, one/node) |
| **S3 Sharded** | 2 | 1 | 2 | true | 1 (split across nodes) |

All three serve the **same** medium model (`MODEL_ID`, default `Qwen/Qwen3-8B`); only the
deployment topology differs.
