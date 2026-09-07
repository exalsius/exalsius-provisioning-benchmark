#!/usr/bin/env bash
# Phase 3 — Deploy. Render + apply the scenario WorkspaceDeployment onto the
# adopted cluster and wait for the llm-d endpoint. Defines phase_deploy.

# Replace any huggingfaceToken value in a persisted YAML with a placeholder, so
# the run directory never keeps the plaintext secret. Best-effort (no-op if the
# file is absent or holds no token).
_redact_hf_token() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -i 's#\(huggingfaceToken:\)[[:space:]]*.*#\1 "***REDACTED***"#' "$file" 2>/dev/null || true
}

phase_deploy() {
  local logf="$RUN_DIR/deploy.log"; : > "$logf"
  resolve_hf_token   # rendered into the WorkspaceDeployment (also when run via --from deploy)
  export KUBECONFIG="$KUBECONFIG_OUT"

  render "$WORKFLOW_ROOT/templates/workspacedeployment.yaml.tmpl" \
         "$RUN_DIR/manifests/workspacedeployment.yaml"
  run kc apply -f "$RUN_DIR/manifests/workspacedeployment.yaml" 2>&1 | tee -a "$logf"
  # The rendered manifest carries the HF token (a secret-typed value the operator
  # needs at apply time). Redact it from the persisted artifact immediately after
  # apply, so the run directory never retains the plaintext secret (it could
  # otherwise leak via CI artifacts or archived runs).
  _redact_hf_token "$RUN_DIR/manifests/workspacedeployment.yaml"

  # NOTE: no vLLM scrape object is created here — the llm-d-stack prerequisite
  # (installed by the operator) / the llm-d-model chart ship their own
  # ServiceMonitor/PodMonitor, which the KOF VM operator picks up.

  # Wait for the workspace to become ready. We accept either an Available or
  # Ready condition = True.
  wait_for "$TIMEOUT_WORKSPACE" "WorkspaceDeployment/$WORKSPACE_NAME ready" bash -c '
    KUBECONFIG="'"$KUBECONFIG_OUT"'" kubectl -n "'"$WORKSPACE_NAMESPACE"'" \
      get workspacedeployment "'"$WORKSPACE_NAME"'" \
      -o jsonpath="{.status.conditions[*].status}" 2>/dev/null | grep -q True'

  kc -n "$WORKSPACE_NAMESPACE" get workspacedeployment "$WORKSPACE_NAME" -o yaml \
    > "$RUN_DIR/manifests/workspacedeployment.status.yaml" 2>/dev/null || true
  # The live CR echoes the token back in spec.values — redact the dump too.
  _redact_hf_token "$RUN_DIR/manifests/workspacedeployment.status.yaml"
  kc -n "$WORKSPACE_NAMESPACE" get pods -o wide 2>/dev/null | tee -a "$logf" || true

  _discover_endpoint | tee "$RUN_DIR/endpoint.env"
  info "workspace deployed"
}

# Record the per-model workspace Service as the inference endpoint (derived in
# load_config: wsd-<cluster>-<workspace>-http in ws-<workspace>, port 8000).
# Write SERVICE/PORT/NAMESPACE to stdout (sourced by the execute phase).
_discover_endpoint() {
  local ns="$ENDPOINT_NAMESPACE" svc="$ENDPOINT_SERVICE" port
  # Prefer the Service's actual port; fall back to the configured default.
  port="$(kc -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  [[ -n "$port" ]] || port="${ENDPOINT_PORT:-8000}"
  printf 'ENDPOINT_NAMESPACE=%s\nENDPOINT_SERVICE=%s\nENDPOINT_PORT=%s\n' "$ns" "$svc" "$port"
  kc -n "$ns" get svc "$svc" >/dev/null 2>&1 || warn "endpoint Service $svc not found in $ns yet"
}
