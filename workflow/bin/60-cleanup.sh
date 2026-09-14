#!/usr/bin/env bash
# Phase 6 — Cleanup. Delete the workspace, then destroy the whole cluster (not a
# reboot — see run-repeat.sh). Defines phase_cleanup.
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
  # We operate ONLY on THIS run's k0sctl.yaml — never a previous run's. If the
  # current run never got as far as generating one (e.g. an EXIT-trap cleanup
  # after a preflight failure, or `--only cleanup` pointed at the wrong run id),
  # skip the reset rather than risk resetting an unrelated cluster.
  local cfg="$RUN_DIR/manifests/k0sctl.yaml"
  if [[ -f "$cfg" ]]; then
    log "k0sctl reset (destroying the cluster on the nodes)"
    run k0sctl reset --config "$cfg" --force --disable-telemetry 2>&1 | tee -a "$logf" || \
      warn "k0sctl reset reported errors (see $logf)"
  else
    warn "no k0sctl.yaml in this run (${RUN_DIR#"$WORKFLOW_ROOT"/}); skipping reset."
    warn "to tear down a specific run, re-run: run.sh $SCENARIO --only cleanup --run-id <that run's id>"
  fi

  # Drop the local kubeconfig so preflight of the next run starts clean.
  [[ "${DRY_RUN:-0}" == "1" ]] || rm -f "$KUBECONFIG_OUT" || true

  # Sanitize the run artifacts IN PLACE, now that the cluster is gone and nothing
  # else needs the real values (k0sctl.yaml was used for the reset just above).
  # This scrubs SSH user/key-path, node public/private addresses + hostname, and
  # any HF token across every recorded file (see lib/sanitize.sh). Every step above
  # is best-effort (`|| true`/`|| warn`) so an ordinary failure doesn't stop this
  # function short of sanitizing; run.sh's EXIT trap additionally calls
  # sanitize_run_dir directly as a last resort if this function is ever aborted
  # (e.g. a `set -e` failure in a step we didn't anticipate) before reaching here.
  # Together these make sanitization run on both a clean finish and any
  # failure-path cleanup, so recorded runs are always safe to share. (Skipped for
  # --keep, where cleanup does not run and the cluster stays up.)
  if [[ "${DRY_RUN:-0}" != "1" ]] && declare -F sanitize_run_dir >/dev/null; then
    sanitize_run_dir "$RUN_DIR" && info "run artifacts sanitized"
  fi
  info "cleanup complete — k0s cluster torn down on the node(s)"
}
