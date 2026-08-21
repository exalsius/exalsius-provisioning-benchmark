# End-to-end experiment workflow

Reusable, containerised, reproducible workflow that drives every benchmark scenario through the
same phases: **bootstrap → prepare → deploy → execute → collect → cleanup**. It implements the
end-to-end flow specified in [`../docs/specs/common-experiment-setup.md`](../docs/specs/common-experiment-setup.md)
and is reused unchanged across Scenarios 1–3 (only per-scenario config differs).

## What it does

One self-contained cluster per run (management == target). Observability is
**k0rdent KOF** — a VictoriaMetrics storage layer (metrics/logs/traces) plus OpenTelemetry
collectors — run *regionless* (the single cluster stores its own telemetry). k0rdent-istio is not
used.

| Phase | Script | Action |
|-------|--------|--------|
| preflight | [`bin/00-preflight.sh`](bin/00-preflight.sh) | Check tooling, inputs, SSH/GPU reachability, node count. |
| bootstrap | [`bin/10-bootstrap.sh`](bin/10-bootstrap.sh) | `k0sctl` brings up k0s on the provided SSH nodes; export kubeconfig. |
| prepare | [`bin/20-prepare.sh`](bin/20-prepare.sh) | Install OpenEBS (default StorageClass) + GPU operator; k0rdent/KCM; **KOF** (VictoriaMetrics storage + OTel collectors, regionless); exalsius-operator; **adopt** the cluster into k0rdent; register the workspace catalog (HelmRepository → ServiceTemplates → `llm-d-model-0-3-0` WorkspaceClass). |
| deploy | [`bin/30-deploy.sh`](bin/30-deploy.sh) | Render + apply the scenario `WorkspaceDeployment`; wait for the endpoint. |
| execute | [`bin/40-execute.sh`](bin/40-execute.sh) | Functional probe (in-cluster curl) + load probe (**aiperf** as an in-cluster Job). |
| collect | [`bin/50-collect.sh`](bin/50-collect.sh) | Snapshot required metric series from **VictoriaMetrics** (KOF); write `run-report.md`. |
| cleanup | [`bin/60-cleanup.sh`](bin/60-cleanup.sh) | Delete the workspace, then `k0sctl reset` — nodes return to bare. |

## Prerequisites

- **Operator host** (laptop / CI): **Docker** only — every tool the workflow needs (`k0sctl`,
  `kubectl`, `helm`, `jq`, `envsubst`, `ssh`, `base64`) is bundled in the container image
  (`make build`). The workflow is run exclusively inside that container.
- **Provided nodes**: 1 (S1) or 2 (S2/S3) NVIDIA **L40** nodes reachable over SSH with
  passwordless `sudo` (see the spec for the full infrastructure assumptions).
- **Run inputs** — passed to `make docker-run` via the environment (or the `RUN_ID` /
  `SSH_KEY_PATH` make variables), and **prompted interactively in the container** when unset. In CI
  there is no TTY, so pass them all explicitly:
  - **Run identifier** (`RUN_ID`) — names the run directory `runs/<scenario>/<run-id>/`. If the
    directory already exists you're asked to purge it or abort (cleanup runs reuse it without asking).
  - `NODE_ENDPOINTS` — the provided nodes (comma-separated `ip:port`).
  - **SSH username & key** — never assumed (no guessed user, no personal key). `SSH_USERNAME` is
    forwarded into the container; `SSH_KEY_PATH` (prompted by `make` if unset) is mounted read-only.
  - `HF_TOKEN` — Hugging Face read token (model weights + aiperf tokenizer); prompted with hidden
    input. Never committed or echoed.

## Quickstart

Everything runs inside the bundled container — the only host requirement is Docker.

```bash
cd workflow

# Build the image once (bundles every tool the workflow needs):
make build

# Run a scenario end-to-end in the container. Anything not preset is prompted
# (SSH key path, node endpoints, SSH username, HF token, run id):
make s1                                                    # or: make docker-run SCENARIO=s1

# ...or preset inputs to skip the prompts (and for CI):
export HF_TOKEN=hf_xxx
export NODE_ENDPOINTS="10.0.0.1:22,10.0.0.2:22"            # S2/S3 need two; S1 one
export SSH_USERNAME=ubuntu
make docker-run SCENARIO=s2 RUN_ID=exp-01 SSH_KEY_PATH=~/.ssh/bench
```

Forward run flags to the in-container `run.sh` via `RUN_FLAGS` — e.g. keep the cluster up, run a
subset of phases, or preview commands without touching anything:

```bash
make docker-run SCENARIO=s1 RUN_FLAGS="--to collect --keep"   # everything except cleanup
make docker-run SCENARIO=s1 RUN_FLAGS="--dry-run"             # preview the commands only
make docker-cleanup SCENARIO=s1                               # tear the cluster down later
```

## Configuration

- [`config/common.env`](config/common.env) — shared defaults: model, chart names/versions,
  namespaces, adoption template, load parameters.
- [`config/scenario-s1.env`](config/scenario-s1.env) / `-s2` / `-s3` — the per-scenario topology
  deltas (`DECODE_REPLICAS`, `GPU_COUNT_PER_REPLICA`, `EXPECTED_NODE_COUNT`, names). These are the
  only differences between scenarios.

The forwarded knobs (`MODEL_ID`, `NODE_ENDPOINTS`, `SSH_USERNAME`, `DECODE_REPLICAS`,
`GPU_COUNT_PER_REPLICA`, …) can be overridden from the environment, e.g.
`MODEL_ID=Qwen/Qwen3-32B make docker-run SCENARIO=s3`.

## Scenario → topology

| | Nodes | `DECODE_REPLICAS` | `GPU_COUNT_PER_REPLICA` | Meaning |
|--|:--:|:--:|:--:|--|
| **s1** single-node | 1 | 1 | 1 | one replica on one GPU |
| **s2** replicated | 2 | 2 | 1 | two replicas, one GPU each |
| **s3** sharded | 2 | 1 | 2 | one replica, tensor-parallel across 2 GPUs/nodes |

The `llm-d-model-0-3-0` WorkspaceClass **injects** these `spec.resources` into the chart:
`resources.replicas → ms.decode.replicas` and `resources.perReplica.gpuCount →
ms.decode.parallelism.tensor` (GPUs-per-replica *is* the tensor-parallel width; there is no
separate `multinode` switch). See
[`templates/workspacedeployment.yaml.tmpl`](templates/workspacedeployment.yaml.tmpl) and
[`templates/workspace-class.yaml`](templates/workspace-class.yaml).

## Artifacts

Each run writes a self-contained, timestamped directory (git-ignored):

```
runs/<scenario>/<run-id>/
├── config.env                 # resolved parameters (secrets redacted)
├── phases.tsv                 # per-phase status ledger
├── preflight.log bootstrap.log prepare.log deploy.log load.log cleanup.log
├── manifests/                 # rendered k0sctl.yaml + all applied CRDs
├── results/                   # functional.json, aiperf.json, aiperf.log
├── metrics/                   # required series snapshots + _present/_missing.txt
└── run-report.md              # acceptance summary (functional) + recorded perf
```

## Acceptance (functional)

A run passes on: provisioning succeeds, the endpoint returns a valid non-empty completion, the
aiperf load export is captured with no request errors, all required metric series are present, and
cleanup leaves the nodes bare. Performance figures (throughput, TTFT, latency) are **recorded and
reported, not gated**. Reproducibility = two consecutive clean runs both passing.
