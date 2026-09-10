#!/usr/bin/env bash
# Shared helpers for the exalsius provisioning benchmark end-to-end workflow.
# Sourced by every phase script. Not meant to be executed directly.

set -euo pipefail

# --- paths -------------------------------------------------------------------
# WORKFLOW_ROOT is the directory containing bin/ lib/ config/ templates/ load/.
WORKFLOW_ROOT="${WORKFLOW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export WORKFLOW_ROOT

# --- logging -----------------------------------------------------------------
_c() { [[ -t 2 ]] && printf '\033[%sm' "$1" >&2 || true; }
log()  { _c '0;36'; printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; _c '0'; }
info() { _c '0;32'; printf '  ✓ %s\n' "$*" >&2; _c '0'; }
warn() { _c '1;33'; printf '  ! %s\n' "$*" >&2; _c '0'; }
err()  { _c '1;31'; printf '  ✗ %s\n' "$*" >&2; _c '0'; }
die()  { err "$*"; exit 1; }

# Run a command, echoing it first. Honours DRY_RUN=1 (print only).
run() {
  _c '0;90'; printf '    $ %s\n' "$*" >&2; _c '0'
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  "$@"
}

require_cmd() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"; done
}

# --- config loading ----------------------------------------------------------
# Loads config/common.env then config/scenario-<SCENARIO>.env, exporting all vars.
load_config() {
  local scenario="${1:?scenario id required (s1|s2|s3)}"
  local common="$WORKFLOW_ROOT/config/common.env"
  local scen="$WORKFLOW_ROOT/config/scenario-${scenario}.env"
  [[ -f "$common" ]] || die "missing $common"
  [[ -f "$scen"   ]] || die "unknown scenario '$scenario' (no $scen)"
  set -a; # shellcheck disable=SC1090
  source "$common"; source "$scen"; set +a
  export SCENARIO="$scenario"
  # Secrets may come from the environment rather than the committed config.
  HF_TOKEN="${HF_TOKEN:-}"
  # The workspace-deployment controller expects the child kubeconfig Secret to be
  # named "<clusterDeployment>-kubeconfig" (derived from CLUSTER_NAME here).
  export KUBECONFIG_SECRET_NAME="${KUBECONFIG_SECRET_NAME:-${CLUSTER_NAME}-kubeconfig}"
  # The model's decode pods live in the workspace's own namespace ws-<workspace>
  # (e.g. ws-s1-single-node); used as the readiness signal before probing.
  export WORKSPACE_SERVICE_NAMESPACE="${WORKSPACE_SERVICE_NAMESPACE:-ws-${WORKSPACE_NAME}}"
}

# --- run directory / artifacts ----------------------------------------------
# Resolve the run identifier (RUN_DIR name). Prompt if not given via --run-id /
# RUN_ID. Fails in non-interactive contexts. Idempotent.
resolve_run_id() {
  if [[ -z "${RUN_ID:-}" ]]; then
    if [[ -t 0 ]]; then
      local ans
      read -r -p "Run identifier (used as the run directory name): " ans
      RUN_ID="$ans"
    else
      die "RUN_ID not set and no TTY to prompt — pass --run-id <id> or set RUN_ID"
    fi
  fi
  [[ -n "$RUN_ID" ]] || die "no run identifier provided"
  [[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid RUN_ID '$RUN_ID' (allowed: A-Za-z0-9 . _ -)"
  export RUN_ID
}

# Establish RUN_DIR = runs/<scenario>/<RUN_ID> (shared across a run's phases).
# Fresh mode (default): if the directory already exists, offer to purge it or
# abort. Reuse mode ("reuse", used by cleanup-only runs): use it as-is, no prompt
# — an existing directory must never block cleanup.
init_run_dir() {
  local reuse="${1:-}"
  RUN_DIR="${RUN_DIR:-$WORKFLOW_ROOT/runs/${SCENARIO}/${RUN_ID:?RUN_ID not set (call resolve_run_id first)}}"
  if [[ "$reuse" != "reuse" && -d "$RUN_DIR" ]]; then
    if [[ -t 0 ]]; then
      local ans
      read -r -p "Run '$RUN_ID' already exists (${RUN_DIR#"$WORKFLOW_ROOT"/}). Delete it? [y/N] " ans
      case "$ans" in
        y|Y|yes|YES) rm -rf "$RUN_DIR"; info "deleted existing run directory — continuing";;
        *) die "run '$RUN_ID' already exists and was kept — aborting (choose a different --run-id)";;
      esac
    else
      die "run directory '${RUN_DIR#"$WORKFLOW_ROOT"/}' already exists (non-interactive) — choose a different RUN_ID"
    fi
  fi
  mkdir -p "$RUN_DIR"/{results,metrics,manifests}
  export RUN_DIR
  # KUBECONFIG for the freshly-bootstrapped cluster lives inside the run dir.
  export KUBECONFIG_OUT="${KUBECONFIG_OUT:-$RUN_DIR/kubeconfig}"
}

# Append a phase result to the run's status ledger (used by the report).
record_phase() {
  local phase="$1" status="$2"
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$phase" "$status" >> "$RUN_DIR/phases.tsv"
}

# --- kubernetes helpers ------------------------------------------------------
kc() { KUBECONFIG="$KUBECONFIG_OUT" kubectl "$@"; }
hlm() { KUBECONFIG="$KUBECONFIG_OUT" helm "$@"; }

# True iff the Service <ns>/<svc> exists and has at least one ready endpoint IP.
svc_has_endpoints() {
  local ns="$1" svc="$2" ips
  ips="$(kc -n "$ns" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [[ -n "$ips" ]]
}

# Wait for a condition, polling. wait_for <timeout-seconds> <description> <cmd...>
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  local deadline=$(( $(date +%s) + timeout ))
  log "waiting (≤${timeout}s) for: $desc"
  until "$@" >/dev/null 2>&1; do
    (( $(date +%s) < deadline )) || die "timeout waiting for: $desc"
    sleep 10
  done
  info "ready: $desc"
}

# Resolve the SSH endpoints of the provided nodes. Prompt if not given via
# NODE_ENDPOINTS. Fails in non-interactive contexts. Idempotent.
resolve_node_endpoints() {
  if [[ -z "${NODE_ENDPOINTS:-}" ]]; then
    if [[ -t 0 ]]; then
      local ans
      read -r -p "SSH endpoint(s) of the provided node(s), comma-separated ip:port: " ans
      NODE_ENDPOINTS="$ans"
    else
      die "NODE_ENDPOINTS not set and no TTY to prompt — set NODE_ENDPOINTS (comma-separated ip:port)"
    fi
  fi
  export NODE_ENDPOINTS
  [[ -n "$NODE_ENDPOINTS" ]] || die "no node endpoints provided"
}

# Resolve the Hugging Face token (secret). Prompt with hidden input if not given
# via HF_TOKEN. Fails in non-interactive contexts. Idempotent.
resolve_hf_token() {
  if [[ -z "${HF_TOKEN:-}" ]]; then
    if [[ -t 0 ]]; then
      local ans
      read -rs -p "Hugging Face token (input hidden): " ans; printf '\n' >&2
      HF_TOKEN="$ans"
    else
      die "HF_TOKEN not set and no TTY to prompt — set HF_TOKEN"
    fi
  fi
  export HF_TOKEN
  [[ -n "$HF_TOKEN" ]] || die "no Hugging Face token provided"
}

# Resolve the SSH username for the provided nodes. Prompt if not given via
# --ssh-user / SSH_USERNAME. Fails in non-interactive contexts. Idempotent.
resolve_ssh_username() {
  if [[ -z "${SSH_USERNAME:-}" ]]; then
    if [[ -t 0 ]]; then
      local ans
      read -r -p "SSH username for the provided nodes [ubuntu]: " ans
      SSH_USERNAME="${ans:-ubuntu}"
    else
      die "SSH_USERNAME not set and no TTY to prompt — pass --ssh-user <name> or set SSH_USERNAME"
    fi
  fi
  export SSH_USERNAME
  info "using SSH username: $SSH_USERNAME"
}

# Resolve the SSH private key for the provided nodes. Never silently assume the
# operator's personal key: use --ssh-key / SSH_KEY_PATH if given, otherwise prompt
# (interactively). Fails in non-interactive contexts so CI must pass it explicitly.
# Idempotent: a no-op once a valid key path is set.
resolve_ssh_key() {
  if [[ -z "${SSH_KEY_PATH:-}" ]]; then
    if [[ -t 0 ]]; then
      local hint="" ans
      [[ -f "$HOME/.ssh/id_rsa" ]] && hint=" [$HOME/.ssh/id_rsa]"
      read -r -p "Path to the SSH private key for the provided nodes${hint}: " ans
      SSH_KEY_PATH="${ans:-${hint:+$HOME/.ssh/id_rsa}}"
    else
      die "SSH_KEY_PATH not set and no TTY to prompt — pass --ssh-key <path> or set SSH_KEY_PATH"
    fi
  fi
  SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"   # expand a leading ~
  export SSH_KEY_PATH
  [[ -n "$SSH_KEY_PATH" ]] || die "no SSH key provided"
  [[ -f "$SSH_KEY_PATH" ]] || die "SSH key not found: $SSH_KEY_PATH"
  info "using SSH key: $SSH_KEY_PATH"
}

# --- VictoriaMetrics (KOF) query helpers -------------------------------------
# Port-forward the vmselect Service and query VictoriaMetrics's PromQL instant-
# query API. Shared by the collect phase (required-series snapshot) and the
# execute phase (gating on EPP endpoint discovery before load — see
# 40-execute.sh). Honors DRY_RUN (no-op).

VM_LOCAL_PORT="${VM_LOCAL_PORT:-18428}"

# vm_query_start <logfile> — start the background port-forward; sets
# VM_QUERY_BASE. Caller must eventually call vm_query_stop (e.g. via a RETURN
# trap in the calling function, matching the rest of this codebase's pattern).
vm_query_start() {
  local logf="$1"
  export VM_QUERY_BASE="http://127.0.0.1:${VM_LOCAL_PORT}"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  kubectl -n "$KOF_NAMESPACE" port-forward "svc/$VM_QUERY_SERVICE" "${VM_LOCAL_PORT}:${VM_QUERY_PORT}" \
    >>"$logf" 2>&1 &
  VM_QUERY_PF_PID=$!
  wait_for 60 "VictoriaMetrics query API up" bash -c "curl -sf ${VM_QUERY_BASE}/health -o /dev/null" || \
    warn "VictoriaMetrics not reachable; queries may return empty"
}

vm_query_stop() { [[ -n "${VM_QUERY_PF_PID:-}" ]] && kill "$VM_QUERY_PF_PID" 2>/dev/null; VM_QUERY_PF_PID=""; }

# vm_query_json <promql> — print the raw VictoriaMetrics instant-query JSON
# response body for <promql> (empty on error or DRY_RUN).
vm_query_json() {
  local q="$1"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  curl -sf --data-urlencode "query=$q" "${VM_QUERY_BASE}${VM_QUERY_PATH}" 2>/dev/null || true
}

# vm_query_scalar <promql> — the first result's numeric value, or empty if the
# query returned no series / errored.
vm_query_scalar() {
  local resp; resp="$(vm_query_json "$1")"
  [[ -n "$resp" ]] && jq -r '.data.result[0].value[1] // empty' <<<"$resp" 2>/dev/null
}

# Split comma-separated NODE_ENDPOINTS into an array of ip:port.
node_endpoints_array() {
  local IFS=','; read -r -a _EP <<< "${NODE_ENDPOINTS:?NODE_ENDPOINTS not set}"
  printf '%s\n' "${_EP[@]}"
}
