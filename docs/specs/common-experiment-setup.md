# Common Experiment Specification (T1)

> **Work package:** WP3 — Exalsius provisioning and experimentation benchmark
> **Status:** Implemented (as-built).
> **Applies to:** [Scenario 1 — Single-node](scenario-1-single-node.md), [Scenario 2 — Replicated](scenario-2-replicated.md), [Scenario 3 — Sharded](scenario-3-sharded.md)

This document defines the **common experiment setup** shared by all three benchmark
scenarios: target infrastructure, deployment configuration conventions, the end-to-end
execution flow, expected outputs, the required telemetry, and the acceptance criteria.
Each scenario specification inherits this document and only states its **deltas**.

The goal of the benchmark is to let a third party **reproduce** the provisioning of an
Exalsius-managed compute environment from a set of provided compute instances
(`SSH IP:Port`), deploy a curated minimal LLM inference workspace, and **validate**
functionality and telemetry collection.

> **Open-source-only constraint.** This benchmark uses **only public Exalsius / OSS components** —
> the `exalsius-operator`, `k0rdent`/KCM, `exalsius-workspace-hub`, k0rdent **KOF** (VictoriaMetrics
> + OpenTelemetry), the NVIDIA GPU operator, and OpenEBS — driven by `k0sctl`/`kubectl`/`helm` and
> tailored scripting. The `exls` CLI and the **closed-source Exalsius SaaS API** are **not used**.
> Note the distinction: **VictoriaMetrics is used**, but as the **OSS** storage layer bundled in
> k0rdent KOF (self-hosted), not the SaaS observability offering. `exals` is itself open-source but
> drives the SaaS API, which is infeasible in a self-hosted OSS-only setup — hence the CRD/Helm-driven
> approach below, reproducible entirely from public artifacts.

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
| **Infrastructure addons** | The **NVIDIA GPU operator** (device plugin + DCGM exporter), **OpenEBS** (default StorageClass), and **k0rdent KOF** (VictoriaMetrics + OpenTelemetry collectors) are installed by **direct `helm install`** into the cluster — *not* via k0rdent MCS/ServiceTemplates. |
| **WorkspaceClass** | `workspaces.exalsius.ai/v1` cluster-scoped CRD binding a workspace-hub Helm template + default values (here `llm-d-model-1-0-0` from workspace-hub 1.0.0, with prerequisite ServiceTemplate `llm-d-infra-1-0-0`). |
| **WorkspaceDeployment** | `workspaces.exalsius.ai/v1` CRD instantiating a WorkspaceClass onto the adopted cluster with `resources` + Helm `values`. The operator realises it (and its `llm-d-infra` prereq ServiceTemplate) as a Sveltos `ServiceSet` — this is the operator's own machinery, not something the benchmark authors. |
| **llm-d** | The reference inference architecture behind the workspace (llm-d 0.9.0): an inference gateway (agentgateway) + router/endpoint-picker in front of one or more vLLM model-server pods (a LeaderWorkerSet). |
| **Observability stack** | Open-source **k0rdent KOF** — VictoriaMetrics (metrics storage) + OpenTelemetry collectors — installed by direct `helm install`, scraping the **NVIDIA DCGM exporter** (GPU-operator `ServiceMonitor`), vLLM `/metrics` (a workflow-applied `PodMonitor`), and the llm-d router's endpoint-picker. KOF's own Grafana bundling is opt-in-only, so this repo applies its own explicit `Grafana`/`GrafanaDatasource` CRs (derived from KOF's own reference implementation, `kof-storage` chart) and one purpose-built dashboard — see [`telemetry.md`](telemetry.md) (T6.1/T6.4). (The SaaS observability API is out of scope; the VictoriaMetrics used here is the OSS KOF one.) |

References: [exalsius-operator](https://github.com/exalsius/exalsius-operator) · [workspace-hub](https://github.com/exalsius/exalsius-workspace-hub) · [k0rdent](https://github.com/exalsius/k0rdent) · [k0rdent KOF](https://docs.k0rdent.io/) · [k0rdent adopting clusters](https://docs.k0rdent.io/latest/admin/clusters/admin-adopting-clusters/).

---

## 2. Target infrastructure (assumptions)

### 2.1 Compute nodes (provided input)

The benchmark is parameterised by a list of provided NVIDIA nodes. Each node MUST satisfy:

| Requirement | Assumption |
|-------------|-----------|
| Access | SSH reachable at `IP:Port` with a username and a private key the operator holds. |
| GPU | **1× NVIDIA GPU per node** (reference: **L40S** 48 GB, on Nebius `gpu-l40s-a`; also validated on H100 80 GB). The medium model (~16 GB bf16) fits one such GPU with ample KV-cache headroom. Because there is **one GPU per node**, Scenario 3's cross-node shard uses `nodesPerReplica: 2`. |
| GPU software | No NVIDIA driver required on the node by default — the NVIDIA GPU operator (installed by direct `helm install` in Phase 2) installs one **≥ 580** (CUDA 13, required by the llm-d 0.9.0 model image) and the NVIDIA container runtime. If the node already has driver ≥ 580 pre-installed, `GPU_OPERATOR_DRIVER_ENABLED=false` uses it instead and skips operator-managed driver install. The in-cluster device plugin + DCGM exporter come from the same GPU operator install either way. |
| OS | Linux x86_64 (Ubuntu 24.04 LTS reference), passwordless `sudo` for the SSH user (k0s bootstrap). |
| Storage | No dynamic provisioner required on the node — the workflow installs **OpenEBS** as the default StorageClass in Phase 2 (KOF/VictoriaMetrics PVCs need one). |
| Networking | SSH reachable from the operator host (for `k0sctl`); outbound internet (pull container images + model weights from Hugging Face). Node-to-node connectivity on the k0s ports (API 6443, konnectivity 8132, etc.) for the multi-node scenarios. |
| Disk | ≥ 60 GB free (container images + model artifacts; the class requests 50 Gi storage per replica). |

> **Scenario node counts:** S1 → 1 node · S2 → 2 nodes · S3 → 2 nodes. See each scenario spec.
> Because the cluster is self-contained, the **k0s control plane is co-located** on a provided
> GPU node (single-node k0s for S1; one controller+worker plus one worker for S2/S3). The
> control-plane/monitoring overhead therefore shares node resources with the workload — see
> §8 known limitations.

### 2.2 Control / operator host

The machine that drives the benchmark (laptop or CI runner). It holds **no pre-existing
cluster** — the benchmark cluster is created on the provided nodes during the run. The **only host
requirement is Docker**: the T2 end-to-end workflow is containerised and bundles every tool it
needs (`k0sctl`, `kubectl`, `helm`, `jq`, `envsubst`, `ssh`, `base64`). The operator supplies at
runtime:

- The private SSH key for the provided nodes (used by `k0sctl`; passwordless `sudo` on nodes).
- A **Hugging Face access token** with read access to the benchmark model (stored as a Secret
  and referenced from the `WorkspaceDeployment`).

> **No `exls` / SaaS.** The workflow never uses the `exls` CLI (which would require the
> closed-source Exalsius SaaS API) — only `k0sctl`, `kubectl`, `helm`, and the benchmark's own
> scripts, all inside the container. The in-cluster load client is **aiperf**, run as a Job.

### 2.3 Model under test ("medium-sized LLM")

A single medium model is used across **all three** scenarios so results are comparable;
only the *deployment topology* changes between scenarios.

| Parameter | Default | Notes |
|-----------|---------|-------|
| `MODEL_ID` | `Qwen/Qwen3-8B` | Open weights, no gated access; ~16 GB in bf16 → fits one GPU. It is the single `model.name` the chart serves and clients send. Overridable. |
| Precision | bf16 (vLLM default) | |
| Context / max-model-len | 8192 | Held constant across scenarios. |

> **"Medium" definition:** a 7–14B-parameter instruction-tuned model. `Qwen/Qwen3-8B` is
> the reproducible default. For Scenario 3, a larger variant (e.g. `Qwen/Qwen3-32B`) MAY be
> substituted to make cross-node sharding *necessary* rather than *demonstrative* — see the
> Scenario 3 spec. The model id is a single parameter (`MODEL_ID`) so all scenarios stay in sync.

---

## 3. Deployment configuration conventions

All scenarios instantiate the same **`llm-d-model-1-0-0`** `WorkspaceClass` via a
`WorkspaceDeployment`; they differ only in its `resources` and one `values` field. The chart owns
the vLLM workload (a **LeaderWorkerSet**) and reads the operator-injected `_exalsius.resources`
directly — there is **no `resourceInjection`**. Topology is:

```
tensor-parallel size = NODES_PER_REPLICA × GPU_COUNT_PER_REPLICA
model copies         = REPLICAS / NODES_PER_REPLICA        (REPLICAS must be a whole multiple)
```

| Concept | `WorkspaceDeployment` field | S1 | S2 | S3 |
|---------|-----------------------------|----|----|----|
| Nodes in benchmark cluster | (`k0sctl.yaml` host count) | 1 | 2 | 2 |
| Replicas (pods) | `spec.resources.replicas` | 1 | 2 | 2 |
| GPUs per pod | `spec.resources.perReplica.gpuCount` | 1 | 1 | 1 |
| Pods per model copy | `spec.values.modelServer.nodesPerReplica` | 1 | 1 | 2 |
| ⇒ model copies | `replicas / nodesPerReplica` | 1 | 2 | 1 |
| ⇒ tensor-parallel size | `nodesPerReplica × gpuCount` | 1 | 1 | 2 |

- **Single-node (S1):** one pod, one GPU, one model copy (TP=1). Baseline.
- **Replicated (S2):** two independent pods (one model each) behind the llm-d router →
  horizontal throughput / availability.
- **Sharded (S3):** two pods that together serve **one** model, tensor-parallel-split across the
  two nodes (`nodesPerReplica: 2`). Tests the cross-node sharding path (a LeaderWorkerSet of size 2).

The model is set with `spec.values.model.name` (the Hugging Face repo id) and the accelerator with
`spec.resources.perReplica.gpuVendor: NVIDIA` (which lets the operator inject the GPU resource
name). There is no manual `helm` editing — the T2 workflow templates the CRD from scenario config.

### 3.1 Canonical parameters (env-driven)

The end-to-end workflow (T2) reads a per-scenario config that templates the `k0sctl.yaml`, the
adopted-cluster registration, the addon `helm install`s, and the WorkspaceDeployment. At minimum:

```
CLUSTER_NAME            # e.g. bench-s1  (adopted ClusterDeployment name)
KCM_NAMESPACE           # e.g. kcm-system
NODE_ENDPOINTS          # comma-separated ip:port list (provided SSH nodes)
SSH_USERNAME
SSH_KEY_PATH            # used by k0sctl to bootstrap k0s over SSH
HF_TOKEN                # Hugging Face read token
MODEL_ID                # default Qwen/Qwen3-8B (the model.name served/routed on)
WORKSPACE_NAME          # e.g. s1-single-node
GPU_VENDOR              # NVIDIA (resolves the GPU resource name)
GPU_COUNT_PER_REPLICA   # GPUs per pod:            1 | 1 | 1
REPLICAS                # model-server pods:       1 | 2 | 2
NODES_PER_REPLICA       # pods per model copy:     1 | 1 | 2
WORKSPACE_CPU           # per-pod CPU request (default 2, well below the class default of 8)
```

---

## 4. End-to-end execution flow (common)

Every scenario runs the same phased flow, implemented in **T2** (`workflow/`). All phases act on
the **one** benchmark cluster (mgmt == target), sharing one artifact directory
`runs/<scenario>/<run-id>/`.

| Phase | Purpose | Reference actions | Produces |
|-------|---------|-------------------|----------|
| **0. Preflight** | Validate inputs + host: tooling present, SSH reachability + passwordless sudo to every node, node count, low-level PCI GPU probe, no prior cluster of this name. | `ssh … true`; PCI probe | `preflight.log` |
| **1. Bootstrap cluster** | Template `k0sctl.yaml` from the node list, tune node limits, bring up k0s on the provided SSH nodes; export the kubeconfig. | `k0sctl apply`; `k0sctl kubeconfig` | benchmark kubeconfig, `bootstrap.log` |
| **2. Prepare cluster** | `helm install` **OpenEBS** (default StorageClass), Gateway API CRDs, the **NVIDIA GPU operator**, **k0rdent/KCM** (+ provider trim), **KOF** (VictoriaMetrics + OTel collectors), and the **`exalsius-operator`**; **adopt** the cluster (→ `ClusterDeployment`); register the workspace catalog (HelmRepository → ServiceTemplates → `llm-d-model-1-0-0` WorkspaceClass). Wait until GPUs are schedulable. | `helm upgrade --install …`; `kubectl apply`; `kubectl wait` | `prepare.log` |
| **3. Deploy workspace** | Render + apply the scenario `WorkspaceDeployment`; wait for the model's workspace namespace to appear; apply the vLLM `PodMonitor`; discover the endpoint. | `kubectl apply`; `kubectl get ns` (polled) | `endpoint.env`, `deploy.log` |
| **4. Execute** | Functional probe (in-cluster curl to the gateway with the model header), then the standard inference load via an **aiperf** Job in-cluster. | curl pod; aiperf Job | `results/functional.json`, `results/aiperf.json`, `load.log` |
| **5. Collect** | Snapshot the required telemetry from **VictoriaMetrics** (`vmselect`), gather logs, write the run report. Fails if any required series is missing, or if the `WorkspaceDeployment`'s Ready/Available condition never reads `True`. | VM query API; `kubectl logs`; `kubectl get workspacedeployment` (polled) | `metrics/*.json`, `run-report.md` |
| **6. Cleanup** | Delete the WorkspaceDeployment + ClusterDeployment, then **destroy the whole cluster** (`k0sctl reset`) so the nodes return to a clean state. | `kubectl delete`; `k0sctl reset` | `cleanup.log` |

**Idempotency & clean state:** phase 0 fails fast if a cluster of the same name already exists;
phase 6 (`k0sctl reset`, operating only on this run's `k0sctl.yaml`) is safe to run repeatedly and
must leave **nothing benchmark-created on the nodes**. Note that `k0sctl reset` does not reboot the
node, so it does not guarantee a literal bare-metal state (k0s state or NVIDIA driver modules can
persist across a reset without a reboot — see k0s's and NVIDIA's own uninstall/reset guidance).
Reproducibility (T3.2/T4.2/T5.2) requires **two consecutive clean runs** on the same prepared host
(fresh k0s cluster → full run → cluster torn down, twice), not on a rebooted/bare node.

### 4.1 Standard inference workload

To make scenarios comparable, all use the same request workload against the OpenAI-compatible
endpoint (the shared agentgateway, with the `X-Gateway-Model-Name` header), driven by **aiperf**
run in-cluster as a Kubernetes Job:

- **Functional probe:** a single fixed prompt with deterministic decoding
  (`temperature=0`, `max_tokens=128`); the completion is captured as a result artifact.
- **Load probe (aiperf):** `LOAD_N_PROMPTS=200` requests, input ≈ 512 tokens, output = 128 tokens,
  target concurrency `LOAD_CONCURRENCY` (default 16), with a warm-up. Reports throughput
  (tokens/s), TTFT, inter-token latency, and end-to-end latency percentiles.

---

## 5. Expected outputs (common)

Each run produces a self-contained artifact directory:

```
runs/<scenario>/<run-id>/
├── config.env                 # exact parameters used (secrets excluded)
├── phases.tsv                 # per-phase status ledger
├── preflight.log bootstrap.log prepare.log deploy.log load.log cleanup.log
├── manifests/                 # rendered k0sctl.yaml + applied CRDs (HF token redacted)
├── results/
│   ├── functional.json        # prompt + completion of the functional probe
│   ├── aiperf.json            # aiperf load summary export
│   └── aiperf.log             # aiperf Job pod log
├── metrics/
│   ├── _present.txt / _missing.txt   # telemetry acceptance gate
│   └── <series>.json          # snapshot of each required metric series
└── run-report.md              # human-readable summary + functional pass/fail + recorded perf
```

---

## 6. Required metrics (common baseline)

Full definitions, units, labels, granularity, and interpretation are documented in
[`telemetry.md`](telemetry.md) (**T6.1**); this section fixes the **minimum required series** every
scenario must collect. Sources: vLLM (`/metrics`, `vllm:` prefix, via a workflow-applied
`PodMonitor`), the NVIDIA DCGM exporter (GPU-operator `ServiceMonitor`), and the llm-d router's
endpoint-picker (EPP, router-subchart `ServiceMonitor`) — all scraped by the **KOF collectors** into
**VictoriaMetrics**, and visualised in **Grafana**. `telemetry.md` explains the selection
philosophy behind this specific set (why not every llm-d component's metrics, for instance).
The collect phase gates on these exact series being present and non-empty:

| Category | Metric (series) | Unit | Purpose |
|----------|-----------------|------|---------|
| **Infra utilisation** | `DCGM_FI_DEV_GPU_UTIL` | % | GPU compute utilisation per GPU |
| | `DCGM_FI_DEV_FB_USED` | MiB | GPU memory footprint (validates model fit / shard split) |
| | `DCGM_FI_DEV_POWER_USAGE` | W | Power draw |
| **Inference execution** | `vllm:num_requests_running` | count | In-flight requests / saturation — per-pod, one of S2's two load-distribution proofs |
| | `vllm:time_to_first_token_seconds_count` / `_sum` | count / s | TTFT histogram sample count + cumulative sum — the pair depicts live average TTFT (`rate(sum)/rate(count)`) |
| | `vllm:e2e_request_latency_seconds_count` / `_sum` | count / s | Same pairing for end-to-end request latency |
| | `vllm:generation_tokens_total` | tokens | Output token throughput (rate) |
| | `vllm:kv_cache_usage_perc` | ratio | KV-cache pressure (renamed from `gpu_cache_usage_perc` in vLLM ≥0.9) |
| **Routing / backend discovery** | `inference_pool_ready_pods` | count | EPP-discovered ready backend endpoints — proves the router can actually route to every replica, not just that the pod is `Ready` |
| | `inference_pool_per_pod_queue_size` | count | EPP's own per-backend queue depth (one series per model-server pod, see `telemetry.md`) — a routing-pressure diagnostic, not a load-balancing proof: reads 0 whenever the router isn't backlogged |
| **Deployment status** | phase timings from `phases.tsv` (provision/deploy→ready durations) | s | Provisioning success & speed |
| **Scenario-specific** | see each scenario spec | | Replication balance (S2), shard split (S3) |

> Recorded performance values (throughput, TTFT, latency percentiles) come from the aiperf export
> and are written into `run-report.md`; they are **reported, not gated**.

---

## 7. Acceptance criteria (common)

The acceptance criteria are **functional**: a run passes on whether the scenario provisions,
serves, and is observable — not on hitting performance targets. Performance figures are
**recorded and reported** in the run artifacts, but are **not pass/fail gates**. A scenario run
**passes** iff all of the following hold (scenario specs add functional criteria of their own):

1. **Provisioning.** `k0sctl` brings up k0s on the SSH nodes; the cluster is adopted
   (`ClusterDeployment` `Ready`) with GPUs schedulable; the model's workspace namespace appears —
   evidence that the `WorkspaceDeployment` has moved past the shared `llm-d-infra` prerequisite and
   applied the model's `ServiceSet`. Deploy-phase **sequencing** waits on this namespace signal
   rather than the `WorkspaceDeployment`'s own `Available`/`Ready` condition, because that condition
   can report `True` while the shared prerequisite is still installing — gating sequencing on it
   would let a run proceed before the model's `ServiceSet` even exists. The condition is still a
   hard pass/fail requirement, just checked later: the collect phase polls it (bounded, once the
   model has already been proven serving per criterion 2) and **fails the run** if it never reads
   `True`, recording the observed status in `run-report.md`. The collect phase also verifies **pod
   placement**: no two model-server pods (independent replicas or members of the same
   LeaderWorkerSet group) share a node — every current scenario runs 1 GPU/pod on 1-GPU/node
   reference hardware, so this both sanity-checks scheduling (S2's "one replica per node") and
   proves genuine cross-node placement for a sharded model copy (S3), gated by comparing each
   LWS-labeled pod's `.spec.nodeName`, recorded in `results/pod-placement.txt`.
2. **Functionality.** The OpenAI-compatible endpoint returns a valid, non-empty completion for
   the functional probe prompt (HTTP 200, coherent text, expected model id).
3. **Serving stability.** The aiperf load probe completes with a **0% error rate**. Its throughput
   and latency are recorded, not gated.
4. **Telemetry.** Every metric series in §6 is **present and non-empty** in VictoriaMetrics for the
   run window (the collect phase fails otherwise), and visible in Grafana (T6.4).
5. **Reproducibility.** **Two consecutive** clean-state runs both pass, with stored logs,
   config, and result artifacts per §5.
6. **Cleanup.** Phase 6 (`k0sctl reset`) destroys the cluster on the nodes (not a reboot; see §4's
   idempotency note).

> Phase timings (see each scenario's *Indicative timings*) are informational — **not** gates.

---

## 8. Out of scope for WP

- Model quality / accuracy evaluation — the benchmark validates *provisioning, deployment,
  serving functionality, and telemetry*, not model output quality.

### 8.1 Known limitations of the self-contained topology

- **Control-plane co-location:** the k0s control plane, k0rdent/KCM, the operator, and KOF all run
  on the provided GPU node(s) alongside the workload. This consumes CPU/RAM (and a little
  GPU-node scheduling capacity) that a dedicated management cluster would offload — a deliberate
  trade-off for compactness (hence `WORKSPACE_CPU` defaults to 2, well below the class default of 8,
  and the KCM provider list is trimmed to `projectsveltos` only — no k0smotron, as the cluster is
  adopted, not CAPI-provisioned).
- **No management-plane persistence:** because the whole cluster is destroyed at cleanup, k0rdent
  state and historical metrics do not survive a run; result artifacts (§5) are the durable record
  (KOF/VictoriaMetrics retention is deliberately short).
- **S1 single-node** runs control plane + workload on one machine; if that node lacks headroom
  for both k0s/monitoring and the model, reduce monitoring scope or model size.

---

## 9. Assumptions & dependencies

The concrete artifacts and pinned versions that satisfy these are produced by the **T2** workflow.

- **Nodes.** Each provided node has a **single NVIDIA GPU** (L40S 48 GB reference; H100 validated),
  reachable over SSH with passwordless `sudo`. No driver pre-installed is required by default (§3);
  the GPU Operator installs one ≥ 580. Each scenario gets exactly the nodes it needs (S1: 1, S2/S3:
  2) and provisions a fresh cluster on them.
- **Model.** All scenarios serve `MODEL_ID` (default `Qwen/Qwen3-8B`); it fits one GPU, so S3
  exercises the cross-node sharding path demonstratively.
- **Cluster bootstrap.** k0s via `k0sctl` (versions pinned by the T2 workflow; k0s ≥ 1.32 is
  required by KCM's flux pre-check).
- **Cluster management.** The cluster is **adopted into k0rdent** (yielding a `ClusterDeployment`);
  the T2 workflow provides the adoption manifests.
- **Addons.** **OpenEBS**, the **NVIDIA GPU operator**, and **k0rdent KOF** are installed by direct
  `helm install` at versions pinned by the T2 workflow.
- **Workspace.** Scenario topology is expressed through `WorkspaceDeployment` `resources`/`values`
  against the `llm-d-model-1-0-0` WorkspaceClass (`replicas`, `perReplica.gpuCount`,
  `perReplica.gpuVendor`, `modelServer.nodesPerReplica`); the prerequisite `llm-d-infra-1-0-0` is
  auto-installed by the operator.
- **Telemetry retention.** VictoriaMetrics retention is short (the cluster is ephemeral); required
  metrics are snapshotted into run artifacts during Phase 5, which are the durable record.
