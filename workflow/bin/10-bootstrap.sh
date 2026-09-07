#!/usr/bin/env bash
# Phase 1 — Bootstrap. Create a k0s cluster on the provided SSH nodes and export
# its kubeconfig. Defines phase_bootstrap.

# Emit a k0sctl.yaml from NODE_ENDPOINTS. First node = controller+worker
# (control-plane co-located); any remaining nodes = worker.
_gen_k0sctl_yaml() {
  local out="$1"
  {
    cat <<YAML
apiVersion: k0sctl.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
spec:
  hosts:
YAML
    local first=1 ep host port role
    while read -r ep; do
      host="${ep%%:*}"; port="${ep##*:}"; [[ "$port" == "$host" ]] && port=22
      # First node hosts the control plane co-located with the workload.
      # controller+worker nodes are tainted node-role.kubernetes.io/master:NoSchedule
      # by default; --no-taints removes it so benchmark workloads (and add-ons) can
      # schedule there — essential for the single-node S1 and for using both GPUs.
      cat <<YAML
    - role: $([[ $first -eq 1 ]] && echo controller+worker || echo worker)
      ssh:
        address: ${host}
        user: ${SSH_USERNAME}
        port: ${port}
        keyPath: ${SSH_KEY_PATH}
YAML
      if [[ $first -eq 1 ]]; then
        cat <<YAML
      installFlags:
        - --no-taints
YAML
        first=0
      fi
    done < <(node_endpoints_array)
    cat <<YAML
  k0s:
    version: ${K0S_VERSION}
YAML
  } > "$out"
}

# Raise inotify/file-descriptor limits on each node before k0s starts — the
# default kernel limits are too low for the many watchers KOF/operators/otel spin
# up. Best-effort, persistent.
_tune_nodes() {
  local logf="$1" ep host port
  while read -r ep; do
    host="${ep%%:*}"; port="${ep##*:}"; [[ "$port" == "$host" ]] && port=22
    log "tuning kernel limits on $host (inotify/nofile)"
    run ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      -i "$SSH_KEY_PATH" -p "$port" "$SSH_USERNAME@$host" "
        printf 'fs.inotify.max_user_watches=%s\nfs.inotify.max_user_instances=%s\n' \
          ${NODE_INOTIFY_MAX_USER_WATCHES} ${NODE_INOTIFY_MAX_USER_INSTANCES} \
          | sudo tee /etc/sysctl.d/99-benchmark.conf >/dev/null
        sudo sysctl --system >/dev/null 2>&1 || true
        printf '* soft nofile %s\n* hard nofile %s\n' ${NODE_NOFILE_LIMIT} ${NODE_NOFILE_LIMIT} \
          | sudo tee /etc/security/limits.d/99-benchmark.conf >/dev/null
      " >>"$logf" 2>&1 || warn "node tuning failed on $host (non-fatal)"
  done < <(node_endpoints_array)
}

phase_bootstrap() {
  local logf="$RUN_DIR/bootstrap.log"; : > "$logf"
  # Ensure inputs are set when bootstrap runs standalone (--from bootstrap).
  resolve_node_endpoints; resolve_ssh_username; resolve_ssh_key
  local cfg="$RUN_DIR/manifests/k0sctl.yaml"
  _gen_k0sctl_yaml "$cfg"
  info "generated $(basename "$cfg")"

  _tune_nodes "$logf"

  log "k0sctl apply (this provisions k0s on the nodes; may take several minutes)"
  run k0sctl apply --config "$cfg" --disable-telemetry 2>&1 | tee -a "$logf"

  log "exporting kubeconfig -> ${KUBECONFIG_OUT#"$WORKFLOW_ROOT"/}"
  # Dry-run created no cluster and no kubeconfig, so the real readiness checks
  # below would hang/fail against nothing — stop here.
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    info "[dry-run] would export kubeconfig and wait for all nodes Ready"
    return 0
  fi
  k0sctl kubeconfig --config "$cfg" > "$KUBECONFIG_OUT"
  chmod 600 "$KUBECONFIG_OUT"

  wait_for "$TIMEOUT_BOOTSTRAP" "all nodes Ready" \
    bash -c 'KUBECONFIG="'"$KUBECONFIG_OUT"'" kubectl get nodes | grep -qc " Ready "'
  kc get nodes -o wide | tee -a "$logf"
  info "cluster bootstrapped"
}
