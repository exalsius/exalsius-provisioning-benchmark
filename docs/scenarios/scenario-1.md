# Scenario 1 — Single-node inference (runbook)

Operator-facing runbook for **Scenario 1**: provision a single GPU node, deploy one medium LLM
(`Qwen/Qwen3-8B`) as a single vLLM model-server pod, exercise it, collect telemetry, and tear
everything down — all through the containerised end-to-end workflow.

- **Design spec:** [`../specs/scenario-1-single-node.md`](../specs/scenario-1-single-node.md)
  (inherits [`../specs/common-experiment-setup.md`](../specs/common-experiment-setup.md)).
- **Workflow reference:** [`../../workflow/README.md`](../../workflow/README.md).
- **Verification evidence:** [`../evidence/scenario-1/`](../evidence/scenario-1/) (the two clean runs).

Scenario 1 is the **reference implementation** — S2/S3 reuse this exact workflow with only
per-scenario config changed.

---

## 1. Prerequisites

- **Operator host:** Docker only. Every tool the workflow needs (`k0sctl`, `kubectl`, `helm`,
  `jq`, `envsubst`, `ssh`, `base64`) is bundled in the workflow image (`make build`).
- **Provided node:** exactly **one** NVIDIA GPU node — the reference runs use a **Nebius L40S VM**
  (48 GB GPU; see [§2 Reference test environment](#21-reference-test-environment-known-good)) —
  reachable over SSH with **passwordless `sudo`**, outbound internet (pulls container images +
  model weights). **No NVIDIA driver is required on the node by default**: the GPU Operator
  installs one **≥ 580** (CUDA 13, required by the llm-d 0.9.0 image) during `prepare`
  (`GPU_OPERATOR_DRIVER_ENABLED=true`, the default). If the node already has driver ≥ 580
  pre-installed, set `GPU_OPERATOR_DRIVER_ENABLED=false` to use it instead and skip
  operator-managed driver install.
- **Inputs** (prompted in the container when unset; pass explicitly in CI):
  - `NODE_ENDPOINTS` — the node as `ip:port` (e.g. `10.0.0.26:22`).
  - SSH username + private key (`SSH_USERNAME`; key mounted read-only).
  - `HF_TOKEN` — Hugging Face read token for the model + aiperf tokenizer.
  - `RUN_ID` — names the run directory `workflow/runs/s1/<run-id>/`.

## 2. Infrastructure configuration

The single node becomes a self-contained k0s cluster (`bench-s1`) — management and target in one.
The topology is fixed by [`workflow/config/scenario-s1.env`](../../workflow/config/scenario-s1.env):

| Setting | Value | Meaning |
|---|---|---|
| `EXPECTED_NODE_COUNT` | 1 | one provided node |
| `REPLICAS` | 1 | one model-server pod |
| `GPU_COUNT_PER_REPLICA` | 1 | one GPU per pod |
| `NODES_PER_REPLICA` | 1 | single-node (TP = 1×1 = 1) |

Shared defaults are in [`workflow/config/common.env`](../../workflow/config/common.env) (model,
chart versions, `WORKSPACE_CPU=2`, `GPU_VENDOR=NVIDIA`, KOF/VictoriaMetrics query, timeouts). Any
value can be overridden from the environment, e.g. `MODEL_ID=Qwen/Qwen3-32B`.

### 2.1 Reference test environment (known-good)

The committed verification evidence (§8) was produced on **Nebius** VMs — **one VM per benchmark
node** (S1 uses one; S2/S3 use two identical VMs). Any node meeting the §1 prerequisites works;
this is the exact, reproducible baseline:

| Attribute | Value |
|---|---|
| Cloud / region | Nebius · `eu-north1` |
| GPU | 1× **NVIDIA L40S** (48 GB) — platform `gpu-l40s-a` |
| vCPUs | 8 |
| Memory | 32 GiB |
| Boot disk | 1280 GiB SSD (4 KiB block), encryption enabled |
| OS | Ubuntu 24.04 LTS — **plain image, no pre-installed NVIDIA driver** |
| VM type | Regular (no reservation / placement policy) |

**Sizing rationale.** On this 8-vCPU node the model pod shares CPU with the co-located control plane
(k0s + KCM + KOF + GPU operator + sveltos) and the llm-d endpoint-picker (1 CPU on its own). Two
knobs keep it schedulable: `WORKSPACE_CPU=2` (vs the class default of 8 — the GPU does the inference,
so a small CPU request only caps throughput, which is recorded, not gated) and the KCM provider list
trimmed to `projectsveltos` (k0smotron and the cloud CAPI providers are dead weight on an *adopted*
cluster). The ~16 GiB model fits within 32 GiB; the NVIDIA driver (≥ 580) is installed on the bare
Ubuntu 24.04 node by the GPU operator during prepare.

## 3. Execution steps

```bash
cd workflow
make build                       # build the workflow container (once)
make s1 RUN_ID=s1-run-1          # full preflight -> cleanup cycle for Scenario 1
```

Or preset inputs to skip prompts (CI):

```bash
export HF_TOKEN=hf_xxx NODE_ENDPOINTS="10.0.0.26:22" SSH_USERNAME=ubuntu
make docker-run SCENARIO=s1 RUN_ID=s1-run-1 SSH_KEY_PATH=~/.ssh/bench
```

Useful variants (forwarded via `RUN_FLAGS`):

```bash
make docker-run SCENARIO=s1 RUN_FLAGS="--to prepare"        # stop after prepare (inspect manually)
make docker-run SCENARIO=s1 RUN_FLAGS="--to collect --keep" # everything except cleanup
make docker-run SCENARIO=s1 RUN_FLAGS="--dry-run"           # print commands only
make docker-cleanup SCENARIO=s1 RUN_ID=s1-run-1             # tear down later
```

The run executes six phases (`bootstrap → prepare → deploy → execute → collect → cleanup`, plus a
`preflight` gate); see [`workflow/README.md`](../../workflow/README.md) for the per-phase detail.

## 4. Expected outputs

Each run writes `workflow/runs/s1/<run-id>/` (git-ignored locally; the sanitized evidence is
committed under [`../evidence/scenario-1/`](../evidence/scenario-1/)):

```
config.env  phases.tsv  *.log  manifests/
results/    functional.json  aiperf.json  aiperf.log
metrics/    _present.txt  _missing.txt  <series>.json
run-report.md
```

A passing run shows, in `phases.tsv`, every phase `ok`, and in `run-report.md`:

- **Functional probe:** `pass` (a non-empty completion for `Qwen/Qwen3-8B`).
- **aiperf load export captured:** yes, **0 request errors**.
- **Required metric series missing: 0.**
- **WorkspaceDeployment Ready/Available condition:** `True` (gated — checked in the collect phase,
  once the model is already proven serving, rather than during deploy-phase sequencing; see
  [common spec §7.1](../specs/common-experiment-setup.md#7-acceptance-criteria-common)).
- **Recorded performance** (reported, not gated): output-token throughput, request throughput,
  TTFT (p50/p90), request latency (p50/p90), inter-token latency, output sequence length.

### Required metrics (collect-phase gate)

Present + non-empty in VictoriaMetrics or the run fails
([`bin/50-collect.sh`](../../workflow/bin/50-collect.sh)):

`DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_POWER_USAGE`,
`vllm:num_requests_running`, `vllm:time_to_first_token_seconds_count`,
`vllm:e2e_request_latency_seconds_count`, `vllm:generation_tokens_total`,
`vllm:kv_cache_usage_perc`. DCGM comes from the GPU operator's `ServiceMonitor`; the `vllm:*`
series from the workflow-applied `PodMonitor`.

## 5. Result interpretation

- **Functional acceptance** (gated): all phases `ok`, functional probe `pass`, aiperf 0 errors,
  0 missing metric series, `WorkspaceDeployment` Ready/Available `True`, cleanup tears down the k0s
  cluster on the node.
- **Scenario-1 acceptance** (spec §5): **A1.1** exactly one serving pod
  (`kubectl -n ws-s1-single-node get pod -l llm-d.ai/inference-serving=true`); **A1.2**
  `DCGM_FI_DEV_FB_USED` non-zero on exactly one GPU (verified: **43634 MiB** on one NVIDIA L40S — the
  model plus vLLM's KV-cache reservation at `gpu-memory-utilization 0.95`); **A1.3** baseline
  throughput/TTFT recorded for S2/S3 comparison.
- **Baseline** (`Qwen/Qwen3-8B`, concurrency 16, 200 requests): ~131 tok/s output throughput, TTFT
  p50 ~6.5 s, e2e latency p50 ~9.7 s, the two runs within ~4% of each other. This single-node
  baseline is what S2 (throughput scaling) and S3 (sharding overhead) will be measured against.
  Per-run figures: [`../evidence/scenario-1/`](../evidence/scenario-1/).

## 6. Known limitations

- **Reset, not reboot:** cleanup destroys the k0s cluster (`k0sctl reset`) but does not reboot the
  node. Per [k0s's own docs](https://docs.k0sproject.io/stable/reset) and
  [NVIDIA's GPU Operator uninstall guidance](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/26.7/uninstall.html),
  a reset alone does not guarantee a literal bare-metal state — k0s state or loaded driver modules
  can persist without a reboot. Reproducibility here means two consecutive passing runs on a
  freshly-reset k0s cluster on the same prepared host, not on a rebooted/bare node.
- **No redundancy / no scaling:** a single pod on one GPU (contrast S2/S3).
- **Control-plane co-location:** the control plane shares the one node with the model, so CPU is
  tight and requests are kept low (see §2.1 sizing rationale).
- **Ephemeral telemetry:** VictoriaMetrics retention is short; the committed run artifacts are the
  durable record.
- **Cold cache:** the first run pulls the ~10 GB image + model weights and is markedly slower.

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Model pod stuck Pending, `FailedScheduling: Insufficient cpu` | the co-located node is too small for the sum of CPU requests (model + endpoint-picker 1 CPU + control plane) | lower `WORKSPACE_CPU` (default 2) and keep the KCM providers trimmed to `projectsveltos` (no k0smotron); the reference L40S VM has only 8 vCPU |
| vLLM pod CrashLoop, "Failed to infer device type" / no CUDA | pod got **no GPU** — `gpuVendor`/`gpuNodeSelector` missing so the operator injected no `gpuResourceName` | ensure the WorkspaceDeployment sets `resources.perReplica.gpuVendor: NVIDIA` (default via `GPU_VENDOR`); verify `kubectl -n ws-s1-single-node get pod … -o jsonpath` shows `nvidia.com/gpu` |
| vLLM starts but CUDA init fails | NVIDIA driver **< 580** (image is CUDA 13) | upgrade the node driver, or pin the GPU operator to a ≥580 driver branch |
| Collect phase dies "required metric series missing" incl. `vllm:*` | vLLM `PodMonitor` not scraped | confirm the PodMonitor exists in `ws-s1-single-node` and KOF's target-allocator is watching PodMonitors |
| Collect phase dies "WorkspaceDeployment Ready/Available condition never read True" | the CR's own status disagrees with the (already-verified) serving model — an operator-side reconcile issue | inspect `results/workspace-describe.txt` and `kubectl -n kcm-system describe workspacedeployment s1-single-node`; raise `WORKSPACE_READY_CHECK_TIMEOUT` (default 60s) only if this is consistently a slow-converge race, not a real fault |
| `kcm-flux-check` BackoffLimitExceeded | k0s **< 1.32** | use the pinned `K0S_VERSION` (≥ 1.32) in `common.env` |
| PVCs Pending / KOF not ready | no default StorageClass | OpenEBS install failed — check `prepare.log`; `openebs-hostpath` must be the default |
| Gateway returns "route not found" on the probe | missing model header | requests must carry `X-Gateway-Model-Name: <model>` (the workflow sets this) |
| Many controllers crash / "too many open files" | node inotify/nofile limits too low | the workflow tunes these over SSH in bootstrap; check `bootstrap.log` |
| aiperf Job appears to hang | aiperf per-request timeout default is 6 h | `AIPERF_REQUEST_TIMEOUT` caps it (default 300 s) |
| GPU operator image pull 401/403 | NGC repo auth | the workflow uses the GitHub-Pages GPU-operator repo; check `GPU_OPERATOR_REPO_URL` |

More knobs and rationale are documented inline in
[`workflow/config/common.env`](../../workflow/config/common.env).

## 8. Reproduction

Reproducibility (spec §7.5) = **two consecutive clean runs** on a freshly-prepared host, using only
the committed workflow + docs. Each run fully tears down its k0s cluster (`k0sctl reset`), so the
**same node endpoints are reused** across runs on a fresh cluster each time — this does not reboot
the node or guarantee a literal bare-metal state (see [§6 Known limitations](#6-known-limitations)).
One command runs the whole sequence and aborts if any run fails:

```bash
cd workflow
make build
export HF_TOKEN=hf_xxx NODE_ENDPOINTS="10.0.0.26:22" SSH_USERNAME=ubuntu   # preset (no prompts between runs)
make docker-verify SCENARIO=s1 COUNT=2 SSH_KEY_PATH=~/.ssh/bench           # runs s1-run-1 then s1-run-2
```

`docker-verify` calls [`bin/run-repeat.sh`](../../workflow/bin/run-repeat.sh), which runs the
scenario `COUNT` times back-to-back (`s1-run-1`, `s1-run-2`, …). Equivalent manual form:
`make s1 RUN_ID=s1-run-1` then `make s1 RUN_ID=s1-run-2`. Each run must pass §4's criteria and tear
down its k0s cluster on the node.

**Sanitization is automatic.** At the end of each run's cleanup phase the workflow scrubs its
artifacts **in place** ([`workflow/lib/sanitize.sh`](../../workflow/lib/sanitize.sh)): it drops the
kubeconfig and redacts the SSH username, SSH key path, node public/private addresses, node hostname,
and any Hugging Face token across every recorded file (node identities become `NODE_1`,
`NODE_HOST_1`, `NODE_PRIVIP_1`, …). So `runs/` is safe to share as soon as a run finishes.

**Capture the evidence.** Package the two runs into the committed Git LFS tarball (this re-sanitizes
a copy as a safety net):

```bash
cd workflow
./bin/package-evidence.sh s1 s1-run-1 s1-run-2   # -> docs/evidence/scenario-1.tar.gz (run-1/, run-2/)
cd ..
git lfs install
git add docs/evidence/scenario-1.tar.gz docs/evidence/scenario-1/README.md
git commit -m "docs(evidence): scenario-1 verification runs"
```

The tarball ([`../evidence/scenario-1.tar.gz`](../evidence/scenario-1/), indexed by
[`../evidence/scenario-1/README.md`](../evidence/scenario-1/README.md)) is the durable
reproducibility record. To inspect it:

```bash
git lfs install && git lfs pull
tar tzf docs/evidence/scenario-1.tar.gz
```
