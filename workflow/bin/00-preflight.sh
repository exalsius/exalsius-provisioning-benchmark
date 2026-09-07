#!/usr/bin/env bash
# Phase 0 — Preflight. Validate tooling, inputs, and node reachability.
# Defines phase_preflight (sourced by run.sh).

phase_preflight() {
  local logf="$RUN_DIR/preflight.log"; : > "$logf"
  exec 3>&1; # keep a handle to stdout for the tee'd summary

  require_cmd k0sctl kubectl helm jq envsubst ssh base64
  info "required CLIs present"

  # Resolve the required inputs — each prompts when unset (or fails in CI).
  resolve_node_endpoints  # NODE_ENDPOINTS
  resolve_ssh_username    # --ssh-user / SSH_USERNAME
  resolve_ssh_key         # --ssh-key / SSH_KEY_PATH
  resolve_hf_token        # HF_TOKEN (hidden input)

  # Assert the provided node count matches the scenario expectation.
  local n; n=$(node_endpoints_array | wc -l | tr -d ' ')
  [[ "$n" -eq "${EXPECTED_NODE_COUNT}" ]] \
    || die "scenario $SCENARIO expects $EXPECTED_NODE_COUNT node(s), got $n in NODE_ENDPOINTS"
  info "node count ok ($n)"

  # Per-node checks: SSH + passwordless sudo (hard gate, needed for the k0s
  # bootstrap) and a low-level NVIDIA GPU presence probe (soft — informational).
  local ep host port
  local ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  while read -r ep; do
    host="${ep%%:*}"; port="${ep##*:}"; [[ "$port" == "$host" ]] && port=22
    log "checking ssh $SSH_USERNAME@$host:$port"
    run ssh "${ssh_opts[@]}" -i "$SSH_KEY_PATH" -p "$port" \
        "$SSH_USERNAME@$host" 'sudo -n true' >>"$logf" 2>&1 \
      || die "ssh + passwordless sudo check failed for $host (see $logf)"
    info "node reachable, passwordless sudo ok: $host"

    # GPU presence at the PCI level (vendor id 0x10de). We deliberately do NOT
    # use nvidia-smi: the driver/toolkit are installed later by the GPU operator,
    # so the node has no nvidia-smi yet. Probe sysfs (fallback lspci); warn only.
    if run ssh "${ssh_opts[@]}" -i "$SSH_KEY_PATH" -p "$port" "$SSH_USERNAME@$host" \
         'grep -qil 10de /sys/bus/pci/devices/*/vendor 2>/dev/null || lspci 2>/dev/null | grep -qi nvidia' \
         >>"$logf" 2>&1; then
      info "NVIDIA GPU detected (PCI) on $host"
    else
      warn "no NVIDIA GPU confirmed at PCI level on $host — continuing (verify the node has an L40)"
    fi
  done < <(node_endpoints_array)

  # Refuse to clobber an in-progress cluster of the same name.
  if [[ -f "$KUBECONFIG_OUT" ]] && kc get ns "$KCM_NAMESPACE" >/dev/null 2>&1; then
    die "a live kubeconfig for '$CLUSTER_NAME' already exists ($KUBECONFIG_OUT); run cleanup first"
  fi
  info "preflight passed"
}
