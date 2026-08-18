# Common Experiment Specification (T1)

> **Work package:** WP3 — Exalsius provisioning and experimentation benchmark
> **Status:** Draft (design-only; no live infrastructure exercised yet)
> **Applies to:** [Scenario 1 — Single-node](scenario-1-single-node.md), [Scenario 2 — Replicated](scenario-2-replicated.md), [Scenario 3 — Sharded](scenario-3-sharded.md)

This document defines the **common experiment setup** shared by all three benchmark
scenarios: target infrastructure, deployment configuration conventions, the end-to-end
execution flow, expected outputs, the required telemetry, and the acceptance criteria.
Each scenario specification inherits this document and only states its **deltas**.

The goal of the benchmark is to let a third party **reproduce** the provisioning of an
Exalsius-managed compute environment from a set of provided compute instances
(`SSH IP:Port`), deploy a curated minimal LLM inference workspace, and **validate**
functionality and telemetry collection.

> **Open-source-only constraint.** This benchmark uses **only the public Exalsius
> components** — the `exalsius-operator`, `k0rdent`/KCM, `exalsius-workspace-hub`, and
> `exalsius-grafana-dashboards`, driven by `k0sctl`/`kubectl`/`helm` and tailored scripting.
> The `exls` CLI and the SaaS observability (VictoriaMetrics) are **not used**. Note: `exls` is
> itself open-source, but it drives the **closed-source Exalsius SaaS API**, which makes it
> infeasible in a self-hosted, OSS-only setup — hence the CRD/Helm-driven approach below, which a
> third party can reproduce entirely from public artifacts.

> **Self-contained single-cluster topology.** To stay compact, **the management cluster and the
> target cluster are the same cluster**. Each run bootstraps a fresh Kubernetes cluster
> **directly on the provided SSH nodes** (via `k0sctl`), prepares it in place (installs the
> operators, GPU stack, and monitoring), deploys the scenario workload into it, and finally
> tears the whole thing down (`k0sctl reset`). There is **no separate management cluster** and
> **no `Colony`-driven child-cluster provisioning** — the cluster is *adopted* into k0rdent, not
> provisioned by it.

---

## 1. Terminology (Exalsius open-source model)

| Term | Meaning in this benchmark |
|------|---------------------------|
| **Node** | A provided GPU machine reachable over SSH (`IP:Port`). Becomes a Kubernetes node of the single benchmark cluster, bootstrapped by `k0sctl` (SSH host + key). |
| **Benchmark cluster** | The one k0s cluster created on the provided nodes. It is simultaneously the **management cluster** (runs k0rdent/KCM + `exalsius-operator`) and the **target cluster** (runs the scenario workload). |
| **k0sctl** | Open-source tool that bootstraps/removes k0s over SSH from a declarative `k0sctl.yaml` (host list, roles, key). Used for Phase 1 (create) and Phase 6 (`k0sctl reset`). |
| **Adopted cluster** | The benchmark cluster registered into k0rdent as a managed `ClusterDeployment` (cf. the operator example `default-child-adopted`) so WorkspaceDeployments can target it. |
| **ClusterDeployment** | k0rdent CRD representing a managed cluster. Here it points at the *adopted* local cluster (the deploy target for workspaces). |
| **Infrastructure addons** | The **NVIDIA GPU operator** (device plugin + DCGM exporter) and the **monitoring stack** (Prometheus + Grafana) are installed by **direct `helm install`** into the cluster — *not* via k0rdent MCS/ServiceTemplates. |
| **WorkspaceClass** | `workspaces.exalsius.ai/v1` cluster-scoped CRD binding a workspace-hub Helm template + default values (here `llm-inference`, template `llm-inference-workspace-2.0.0`, prereq `llm-d-stack`). |
| **WorkspaceDeployment** | `workspaces.exalsius.ai/v1` CRD instantiating a WorkspaceClass onto the adopted cluster with `resources` + Helm `values`. The operator realises it (and its `llm-d-stack` prereq ServiceTemplate) as a Sveltos `ServiceSet` — this is the operator's own machinery, not something the benchmark authors. |
| **llm-d** | The reference inference architecture behind the `llm-inference` workspace: an inference scheduler/gateway in front of one or more vLLM decode replicas. |
| **Observability stack** | Open-source **Prometheus + Grafana** installed by direct `helm install` (`kube-prometheus-stack`), with the **NVIDIA DCGM exporter** and vLLM `/metrics`. Dashboards from `exalsius-grafana-dashboards`. (k0rdent's KOF / VictoriaMetrics is an OSS alternative; the SaaS observability is out of scope.) |

References: [exalsius-operator](https://github.com/exalsius/exalsius-operator) · [workspace-hub](https://github.com/exalsius/exalsius-workspace-hub) · [k0rdent](https://github.com/exalsius/k0rdent) · [k0rdent adopting clusters](https://docs.k0rdent.io/latest/admin/clusters/admin-adopting-clusters/) · [exalsius-grafana-dashboards](https://github.com/exalsius/exalsius-grafana-dashboards).

---

## 2. Target infrastructure (assumptions)

### 2.1 Compute nodes (provided input)

The benchmark is parameterised by a list of provided NVIDIA nodes. Each node MUST satisfy:

| Requirement | Assumption |
|-------------|-----------|
| Access | SSH reachable at `IP:Port` with a username and a private key the operator holds. |
| GPU | **1× NVIDIA L40 (48 GB) per node**. The medium model (~16 GB bf16) fits one L40 with ample KV-cache headroom. Because there is **one GPU per node**, Scenario 3's `tensorParallelism: 2` is inherently a **cross-node** split. |
| GPU software | NVIDIA driver ≥ 535 and the NVIDIA container runtime available. The in-cluster device plugin + DCGM exporter are provided by the NVIDIA GPU operator, installed by direct `helm install` in Phase 2. |
| OS | Linux x86_64 (Ubuntu 22.04 LTS reference), passwordless `sudo` for the SSH user (k0s bootstrap). |
| Networking | SSH reachable from the operator host (for `k0sctl`); outbound internet (pull container images + model weights from Hugging Face). Node-to-node connectivity on the k0s ports (API 6443, konnectivity 8132, etc.) for the multi-node scenarios. |
| Disk | ≥ 60 GB free (container images + model artifacts; the class requests 100 Gi storage). |

> **Scenario node counts:** S1 → 1 node · S2 → 2 nodes · S3 → 2 nodes. See each scenario spec.
> Because the cluster is self-contained, the **k0s control plane is co-located** on a provided
> GPU node (single-node k0s for S1; one controller+worker plus one worker for S2/S3). The
> control-plane/monitoring overhead therefore shares node resources with the workload — see
> §8 known limitations.

### 2.2 Control / operator host

The machine that drives the benchmark (laptop or CI runner). It holds **no pre-existing
cluster** — the benchmark cluster is created on the provided nodes during the run. All tooling
is open-source:

- `k0sctl` — bootstrap/remove the k0s cluster over SSH on the provided nodes.
- `kubectl` + `helm` ≥ 3.12 — install k0rdent/KCM + the `exalsius-operator` into that cluster,
  and apply the benchmark CRDs.
- The private SSH key for the provided nodes (used by `k0sctl`; passwordless `sudo` on nodes).
- A **Hugging Face access token** with read access to the benchmark model (stored as a Secret
  and referenced from the `WorkspaceDeployment`).
- Python ≥ 3.10 + `curl`/`jq` for the load client and metric queries; Docker/Podman (the
  end-to-end workflow, T2, is containerised).

> **No `exls` / SaaS.** The operator host never uses the `exls` CLI (which would require the
> closed-source Exalsius SaaS API) — only `k0sctl`, `kubectl`, `helm`, and the benchmark's own
> scripts.

### 2.3 Model under test ("medium-sized LLM")

A single medium model is used across **all three** scenarios so results are comparable;
only the *deployment topology* changes between scenarios.

| Parameter | Default | Notes |
|-----------|---------|-------|
| `MODEL_ID` | `Qwen/Qwen3-8B` | Open weights, no gated access; ~16 GB in bf16 → fits one L40 (48 GB). Overridable. |
| Precision | bf16 (vLLM default) | |
| Context / max-model-len | 8192 | Held constant across scenarios. |

> **"Medium" definition:** a 7–14B-parameter instruction-tuned model. `Qwen/Qwen3-8B` is
> the reproducible default. For Scenario 3, a larger variant (e.g. `Qwen/Qwen3-32B`) MAY be
> substituted to make cross-node sharding *necessary* rather than *demonstrative* — see the
> Scenario 3 spec. The model id is a single parameter (`MODEL_ID`) so all scenarios stay in sync.

---

## 3. Deployment configuration conventions

All scenarios instantiate the same **`llm-inference`** `WorkspaceClass` via a
`WorkspaceDeployment`; they differ only in its `resources` and `values`:

| Concept | `WorkspaceDeployment` field | S1 | S2 | S3 |
|---------|-----------------------------|----|----|----|
| Nodes in benchmark cluster | (`k0sctl.yaml` host count) | 1 | 2 | 2 |
| Decode replicas | `spec.values.decode.replicas` | 1 | 2 | 1 |
| Tensor parallelism | `spec.values.tensorParallelism` | 1 | 1 | 2 |
| Multi-node inference | `spec.values.multinode` | false | false | **true** |
| GPUs per replica | `spec.resources.perReplica.gpuCount` | 1 | 1 | 2 (1 per node) |

- **Single-node (S1):** one replica, one GPU. Baseline.
- **Replicated (S2):** two independent replicas (one per node) behind the llm-d scheduler →
  horizontal throughput / availability. Set `values.decode.replicas: 2`.
- **Sharded (S3):** one replica whose weights are **tensor-parallel-split across two nodes**
  (`values.multinode: true`, `values.tensorParallelism: 2`, `perReplica.gpuCount: 2`). Tests
  the cross-node sharding path.

The llm-d value keys (`decode.replicas`, `tensorParallelism`, `multinode`) are supplied through
the `WorkspaceDeployment.spec.values` passthrough to the `llm-inference-workspace-2.0.0` chart.
There is no manual `helm` editing — the T2 workflow templates the CRD from scenario config, and
pins the exact chart value keys during implementation (see §9).

### 3.1 Canonical parameters (env-driven)

The end-to-end workflow (T2) reads a per-scenario config that templates the `k0sctl.yaml`, the
adopted-cluster registration, the addon `helm install`s, and the WorkspaceDeployment. At minimum:

```
CLUSTER_NAME            # e.g. bench-s1  (adopted ClusterDeployment name)
KCM_NAMESPACE           # e.g. kcm-system
NODE_ENDPOINTS          # comma-separated ip:port list (provided SSH nodes)
SSH_USERNAME
SSH_KEY_PATH            # used by k0sctl to bootstrap k0s over SSH
KUBECONFIG_OUT          # path where Phase 1 writes the benchmark cluster's kubeconfig
HF_TOKEN                # Hugging Face read token
MODEL_ID                # default Qwen/Qwen3-8B
WORKSPACE_NAME          # e.g. s1-single-node
GPU_COUNT_PER_REPLICA   # 1 | 1 | 2
DECODE_REPLICAS         # 1 | 2 | 1
TENSOR_PARALLELISM      # 1 | 1 | 2
MULTINODE               # false | false | true
```

---

## 4. End-to-end execution flow (common)

Every scenario runs the same phased flow. The reusable implementation is delivered in **T2**;
this section defines the contract each phase must satisfy.

All phases act on the **one** benchmark cluster (mgmt == target).

| Phase | Purpose | Reference actions (k0sctl/kubectl/helm/scripts) | Produces |
|-------|---------|-------------------------------------------------|----------|
| **0. Preflight** | Validate operator host + inputs: `k0sctl`/`kubectl`/`helm` present, SSH reachability to every node, HF token valid, no prior cluster of this name. | `k0sctl version`; `ssh -p <port> <user>@<ip> true` | `preflight.log` |
| **1. Bootstrap cluster** | Template `k0sctl.yaml` from the node list and bring up k0s on the provided SSH nodes; export the kubeconfig. | `k0sctl apply --config k0sctl.yaml`; `k0sctl kubeconfig > $KUBECONFIG_OUT` | benchmark kubeconfig, `bootstrap.log` |
| **2. Prepare cluster** | `helm install` the **NVIDIA GPU operator** and the **monitoring stack** (Prometheus/Grafana) directly; `helm install` k0rdent/KCM + `exalsius-operator`; **adopt** the cluster (→ `ClusterDeployment`); apply the `llm-inference` `WorkspaceClass` (its `llm-d-stack` prereq is handled by the operator). Wait until GPUs are schedulable and monitoring is up. | `helm install gpu-operator nvidia/gpu-operator ...`; `helm install monitoring prometheus-community/kube-prometheus-stack ...`; `helm install kcm ...`; `helm install exalsius-operator ...`; `kubectl apply -f adopt-cluster.yaml workspace-class.yaml`; `kubectl wait` | `prepare.log` |
| **3. Deploy workspace** | Apply a `WorkspaceDeployment` (scenario `values`/`resources`) referencing the adopted cluster; wait until the llm-d endpoint is ready. | `kubectl apply -f workspacedeployment.yaml`; `kubectl wait` | endpoint URL, `deploy.log` |
| **4. Execute** | Health-check the OpenAI-compatible endpoint (port-forward/Service), then run the standard inference load. | benchmark client (T2) against `/v1/chat/completions` | `results/*.json`, `load.log` |
| **5. Collect** | Snapshot telemetry (PromQL against the in-cluster Prometheus), logs, and the Grafana dashboard. | Prometheus HTTP query API; `kubectl logs`; export Grafana panels | `metrics/*.json`, `run-report.md` |
| **6. Cleanup** | Delete the WorkspaceDeployment, then **destroy the whole cluster** so the nodes return to a clean state (individual `helm uninstall`s are unnecessary — `k0sctl reset` removes everything). | `kubectl delete workspacedeployment <ws>`; `k0sctl reset --config k0sctl.yaml` | `cleanup.log` |

**Idempotency & clean state:** phase 0 fails fast if a cluster/WorkspaceDeployment of the same
name already exists; phase 6 (`k0sctl reset`) is safe to run repeatedly and must leave **nothing
benchmark-created on the nodes** — no k0s, operators, or workloads. Reproducibility
(T3.2/T4.2/T5.2) requires **two consecutive clean runs** from an empty starting state (bare
nodes → full run → bare nodes, twice).

### 4.1 Standard inference workload

To make scenarios comparable, all use the same request workload against the OpenAI-compatible
endpoint exposed by the llm-d scheduler:

- **Functional probe:** a single fixed prompt with a deterministic decoding config
  (`temperature=0`, `max_tokens=128`); the completion is captured as a result artifact.
- **Load probe:** a fixed request mix — `N_PROMPTS=200`, input ≈ 512 tokens, output = 128
  tokens, at a target concurrency `CONCURRENCY` (default 16). Reports throughput (tokens/s),
  TTFT, and end-to-end latency percentiles.

---

## 5. Expected outputs (common)

Each run produces a self-contained, timestamped artifact directory:

```
runs/<scenario>/<UTC-timestamp>/
├── config.env                 # exact parameters used
├── k0sctl.yaml                # rendered cluster topology for this run
├── preflight.log
├── bootstrap.log  prepare.log  deploy.log  cleanup.log
├── results/
│   ├── functional.json        # prompt + completion of the functional probe
│   └── load.json              # latency/throughput summary
├── metrics/
│   ├── vllm.json              # vllm:* series snapshot
│   ├── gpu.json               # DCGM_FI_DEV_* series snapshot
│   └── deployment.json        # provisioning/deploy timings + status
└── run-report.md              # human-readable summary + pass/fail vs acceptance criteria
```

---

## 6. Required metrics (common baseline)

Full definitions, units, labels, and interpretation are the subject of **T6.1**; this section
fixes the **minimum required series** every scenario must collect. Sources:
vLLM (`/metrics`, `vllm:` prefix), the NVIDIA DCGM exporter, and node-exporter/kubelet — all
scraped by the benchmark cluster's **Prometheus** (installed by direct `helm install` of
`kube-prometheus-stack`) through `ServiceMonitor`/`PodMonitor`, and visualised in **Grafana**.

| Category | Metric (series) | Unit | Purpose |
|----------|-----------------|------|---------|
| **Deployment status** | cluster provision duration; workspace deploy→ready duration; final status (`Ready`); operator-exported reconciliation metrics | s / enum | Provisioning success & speed |
| **Infra utilisation** | `DCGM_FI_DEV_GPU_UTIL` | % | GPU compute utilisation per GPU |
| | `DCGM_FI_DEV_FB_USED` / `DCGM_FI_DEV_FB_FREE` | MiB | GPU memory footprint (validates model fit / shard split) |
| | `DCGM_FI_DEV_POWER_USAGE` | W | Power draw |
| | node CPU / memory (node-exporter) | %, bytes | Host pressure |
| **Inference execution** | `vllm:time_to_first_token_seconds` | s | Latency (TTFT) |
| | `vllm:e2e_request_latency_seconds` | s | End-to-end request latency |
| | `vllm:generation_tokens_total` | tokens | Output token throughput (rate) |
| | `vllm:num_requests_running` / `vllm:num_requests_waiting` | count | Queue depth / saturation |
| | `vllm:gpu_cache_usage_perc` | % | KV-cache pressure |
| **Operator/control-plane** | exalsius-operator + k0rdent controller metrics exported to the cluster | — | Verify T6.2 export reliability (open-source operator metrics, in place of the SaaS `exalsius-api`) |
| **Scenario-specific** | see each scenario spec | | Replication balance (S2), shard split (S3) |

---

## 7. Acceptance criteria (common)

The acceptance criteria are **functional**: a run passes on whether the scenario provisions,
serves, and is observable — not on hitting performance targets. Performance figures (throughput,
latency, GPU-memory footprint) are **recorded and reported** in the run artifacts, but are
**not pass/fail gates**. A scenario run **passes** iff all of the following hold (scenario specs
add functional criteria of their own):

1. **Provisioning.** `k0sctl` brings up k0s on the SSH nodes; the cluster is adopted
   (`ClusterDeployment` `Ready`) with GPUs schedulable and monitoring up; the
   `WorkspaceDeployment` reaches ready — evidenced by logs.
2. **Functionality.** The OpenAI-compatible endpoint returns a valid, non-empty completion for
   the functional probe prompt (HTTP 200, coherent text, expected model id in the response).
3. **Serving stability.** The load probe completes with a **0% error rate** (every request
   returns a valid response). The throughput and latency it measures are recorded, not gated.
4. **Telemetry.** Every metric series in §6 is **present and non-empty** in the benchmark
   cluster's Prometheus for the run window, and visible in Grafana (T6.4). Operator/k0rdent
   control-plane metrics are exported to the cluster (T6.2).
5. **Reproducibility.** **Two consecutive** clean-state runs both pass, with stored logs,
   config, and result artifacts per §5.
6. **Cleanup.** Phase 6 (`k0sctl reset`) destroys the cluster and leaves the nodes bare — no k0s,
   operators, or workloads remain; the nodes are ready for the next clean run.

> Phase timings (see each scenario's *Indicative timings*) are informational expectations used to
> spot regressions and size CI — they are **not** acceptance gates.

---

## 8. Out of scope for WP

- Model quality / accuracy evaluation — the benchmark validates *provisioning, deployment,
  serving functionality, and telemetry*, not model output quality.

### 8.1 Known limitations of the self-contained topology

- **Control-plane co-location:** the k0s control plane, k0rdent/KCM, the operator, and the
  monitoring stack all run on the provided GPU node(s) alongside the workload. This consumes
  CPU/RAM (and a little GPU-node scheduling capacity) that a dedicated management cluster would
  offload — a deliberate trade-off for compactness. Metrics are interpreted with this in mind.
- **No management-plane persistence:** because the whole cluster is destroyed at cleanup, k0rdent
  state and historical metrics do not survive a run; result artifacts (§5) are the durable record.
- **S1 single-node** runs control plane + workload on one machine; if that node lacks headroom
  for both k0s/monitoring and the model, reduce monitoring scope or model size.

---

## 9. Assumptions & dependencies

This specification is complete and self-contained. The following are firm assumptions and
dependencies; the concrete artifacts and pinned versions that satisfy them are produced by the
**T2** end-to-end workflow (implementation), not decided here.

- **Nodes.** Each provided node has a **single NVIDIA L40 (48 GB)** GPU, reachable over SSH with
  passwordless `sudo`. Each scenario is provided exactly the nodes it needs (S1: 1, S2/S3: 2) and
  provisions a fresh cluster on them.
- **Model.** All scenarios serve `MODEL_ID` (default `Qwen/Qwen3-8B`); it fits one GPU, so S3
  exercises the cross-node sharding path demonstratively (see the Scenario 3 known limitations).
- **Cluster bootstrap.** The benchmark cluster is created with **k0s via `k0sctl`**; the exact
  `k0sctl`/k0s versions are pinned by the T2 workflow.
- **Cluster management.** The cluster is **adopted into k0rdent** (yielding a `ClusterDeployment`)
  to serve as the deploy target for the `WorkspaceDeployment`; the T2 workflow provides the
  adoption manifests.
- **Addons.** The **NVIDIA GPU operator** and **`kube-prometheus-stack`** are installed by direct
  `helm install` at versions pinned by the T2 workflow.
- **Workspace.** Scenario topology is expressed entirely through `WorkspaceDeployment`
  `resources`/`values` against the `llm-inference` `WorkspaceClass` (`decode.replicas`,
  `tensorParallelism`, `multinode`, `perReplica.gpuCount`); the T2 workflow pins the exact chart
  value keys for the deployed `llm-inference-workspace-2.0.0` version.
- **Telemetry retention.** Prometheus retention is short (the cluster is ephemeral); required
  metrics are snapshotted into run artifacts during Phase 5, which are the durable record.
