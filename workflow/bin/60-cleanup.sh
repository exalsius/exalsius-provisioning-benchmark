#!/usr/bin/env bash
# Phase 6 — Cleanup. Delete the workspace, then destroy the whole cluster so the
# nodes return to a bare state. Defines phase_cleanup.
# Idempotent and best-effort: cleanup must succeed even from a partial run.

phase_cleanup() {
  local logf="$RUN_DIR/cleanup.log"; : >> "$logf"

  # Delete the workspace first (graceful) if the cluster is still reachable.
  if [[ -f "$KUBECONFIG_OUT" ]]; then
    export KUBECONFIG="$KUBECONFIG_OUT"
    run kc -n "$WORKSPACE_NAMESPACE" delete workspacedeployment "$WORKSPACE_NAME" \
      --ignore-not-found --wait=false 2>&1 | tee -a "$logf" || true
    run kc -n "$KCM_NAMESPACE" delete clusterdeployment "$CLUSTER_NAME" \
      --ignore-not-found --wait=false 2>&1 | tee -a "$logf" || true
  fi

  # Destroy k0s on the nodes. This removes everything installed this run.
  # When cleanup runs standalone (e.g. `--only cleanup` in a fresh run dir), the
  # current dir has no k0sctl.yaml — fall back to the newest previous run's.
  local cfg="$RUN_DIR/manifests/k0sctl.yaml"
  if [[ ! -f "$cfg" ]]; then
    cfg="$(ls -1t "$WORKFLOW_ROOT/runs/$SCENARIO"/*/manifests/k0sctl.yaml 2>/dev/null | head -1 || true)"
    [[ -n "$cfg" ]] && warn "using k0sctl.yaml from a previous run: ${cfg#"$WORKFLOW_ROOT"/}"
  fi
  if [[ -n "$cfg" && -f "$cfg" ]]; then
    log "k0sctl reset (destroying the cluster on the nodes)"
    run k0sctl reset --config "$cfg" --force --disable-telemetry 2>&1 | tee -a "$logf" || \
      warn "k0sctl reset reported errors (see $logf)"
  else
    warn "no k0sctl.yaml found; skipping reset (was the cluster ever bootstrapped?)"
  fi

  # Drop the local kubeconfig so preflight of the next run starts clean.
  [[ "${DRY_RUN:-0}" == "1" ]] || rm -f "$KUBECONFIG_OUT"
  info "cleanup complete — nodes should be bare"
}
