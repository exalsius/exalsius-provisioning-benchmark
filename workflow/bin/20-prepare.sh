#!/usr/bin/env bash
# Phase 2 — Prepare. Install a storage provisioner, the NVIDIA GPU operator,
# k0rdent/KCM, KOF (VictoriaMetrics storage + OTel collectors) and the
# exalsius-operator, adopt the cluster, and register the workspace catalog
# (HelmRepository -> ServiceTemplates -> WorkspaceClass). Defines phase_prepare.

# Add the classic Helm repos we need (nvidia, openebs). Failures here are fatal
# (fail-fast): a missing repo yields a confusing "repo not found" later.
_helm_repos() {
  run hlm repo add nvidia "$GPU_OPERATOR_REPO_URL" --force-update 2>&1 | tee -a "$RUN_DIR/prepare.log"
  run hlm repo add openebs https://openebs.github.io/openebs --force-update 2>&1 | tee -a "$RUN_DIR/prepare.log"
  run hlm repo update nvidia openebs 2>&1 | tee -a "$RUN_DIR/prepare.log"
}

# Bare k0s ships no dynamic storage; KOF/VictoriaMetrics PVCs need a default
# StorageClass. Install OpenEBS; its localpv hostpath class (openebs-hostpath)
# becomes the default. We do NOT `--wait` the
# whole umbrella (NDM etc. can be slow / not needed) — we only need the default
# StorageClass to exist; the hostpath provisioner has ample time to become ready
# before any PVC is created (KOF is installed several steps later).
_install_storage() {
  log "installing OpenEBS $OPENEBS_VERSION (default StorageClass)"
  run hlm upgrade --install openebs "$OPENEBS_CHART" --version "$OPENEBS_VERSION" \
    -n "$OPENEBS_NAMESPACE" --create-namespace \
    -f "$WORKFLOW_ROOT/templates/openebs-values.yaml" --timeout 10m \
    2>&1 | tee -a "$RUN_DIR/prepare.log"
  wait_for 300 "default StorageClass openebs-hostpath present" \
    bash -c 'KUBECONFIG="'"$KUBECONFIG_OUT"'" kubectl get storageclass openebs-hostpath'
}

# Create a Secret holding a kubeconfig that KCM (in-cluster) can use to reach
# this same cluster, for the k0rdent adoption flow.
# NOTE: the k0sctl kubeconfig points at the node's external
# API address. If that is not reachable from inside the cluster, rewrite the
# server to https://kubernetes.default.svc before creating the secret.
_create_adoption_kubeconfig_secret() {
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  # Named "<cluster>-kubeconfig" in the WorkspaceDeployment's namespace so the
  # workspace controller can find it; labelled kcm so k0rdent treats it as managed.
  kc -n "$KCM_NAMESPACE" create secret generic "$KUBECONFIG_SECRET_NAME" \
    --from-file=value="$KUBECONFIG_OUT" \
    --dry-run=client -o yaml | kc apply -f -
  kc -n "$KCM_NAMESPACE" label secret "$KUBECONFIG_SECRET_NAME" \
    k0rdent.mirantis.com/component=kcm --overwrite >/dev/null 2>&1 || true
}

# Wait for all Flux HelmReleases created by the KOF umbrella to become Ready.
# `helm install kof --wait` only blocks until the HelmRelease CRs are *created* —
# the sub-components (kof-mothership, kof-storage, kof-collectors, VM operator)
# are Flux HelmReleases that reconcile asynchronously. Waits on them explicitly,
# including periodic reconcile nudges to dodge Flux races.
_wait_kof_helmreleases() {
  local ns="$KOF_NAMESPACE" timeout="${1:-1200}"
  local deadline=$(( $(date +%s) + timeout )) last_nudge=0 now notready hr
  log "waiting for KOF Flux HelmReleases in '$ns' to be Ready (≤${timeout}s)"
  # Wait for the umbrella to create at least one HelmRelease.
  until [[ -n "$(kc -n "$ns" get helmrelease -o name 2>/dev/null)" ]]; do
    (( $(date +%s) < deadline )) || die "no KOF HelmReleases appeared in '$ns'"
    sleep 5
  done
  while :; do
    # HelmReleases whose Ready condition is not yet True (or absent).
    notready="$(kc -n "$ns" get helmrelease -o json 2>/dev/null | jq -r '
      .items[] | select(([.status.conditions[]? | select(.type=="Ready") | .status] | first) != "True")
      | .metadata.name')"
    if [[ -z "$notready" ]]; then info "all KOF HelmReleases Ready"; return 0; fi
    now=$(date +%s)
    (( now < deadline )) || die "timeout waiting for KOF HelmReleases: $(echo $notready | tr '\n' ' ')"
    # Race mitigation: periodically ask Flux to re-reconcile the pending ones.
    if (( now - last_nudge >= 30 )); then
      for hr in $notready; do
        kc -n "$ns" annotate helmrelease "$hr" \
          "reconcile.fluxcd.io/requestedAt=$(date +%s%N)" --overwrite >/dev/null 2>&1 || true
      done
      last_nudge=$now
    fi
    log "  not ready yet: $(echo $notready | tr '\n' ' ')"
    sleep 10
  done
}

# Trim the KCM Management's provider list to KCM_PROVIDERS so unused cloud CAPI
# providers (aws/azure/gcp/docker/...) are uninstalled — we adopt, not provision.
# Patching (vs. createManagement=false) keeps KCM's own core config intact.
_trim_kcm_providers() {
  wait_for 300 "Management/kcm present" kc get management.k0rdent.mirantis.com kcm
  local prov="" p
  for p in $KCM_PROVIDERS; do prov="${prov:+$prov,}{\"name\":\"$p\"}"; done
  log "trimming KCM providers to: $KCM_PROVIDERS"
  run kc patch management.k0rdent.mirantis.com kcm --type=merge \
    -p "{\"spec\":{\"providers\":[${prov}]}}" 2>&1 | tee -a "$RUN_DIR/prepare.log" || \
    warn "could not patch Management providers (continuing with defaults)"
}

# Install the Gateway API CRDs (experimental channel) required by the llm-d-infra
# workspace prerequisite. Server-side apply: the experimental CRDs exceed the
# client-side apply annotation size limit.
_install_gateway_api() {
  log "installing Gateway API CRDs (experimental $GATEWAY_API_VERSION, server-side)"
  run kc apply --server-side -f "$GATEWAY_API_MANIFEST" 2>&1 | tee -a "$RUN_DIR/prepare.log"
}

phase_prepare() {
  local logf="$RUN_DIR/prepare.log"; : > "$logf"
  resolve_hf_token   # needed for the HF secret (also when run via --from prepare)
  export KUBECONFIG="$KUBECONFIG_OUT"

  _helm_repos
  _install_storage
  _install_gateway_api

  # Values file carries the k0s containerd wiring (templates/gpu-operator-values.yaml).
  log "installing NVIDIA GPU operator $GPU_OPERATOR_VERSION (driver.enabled=$GPU_OPERATOR_DRIVER_ENABLED)"
  run hlm upgrade --install gpu-operator "$GPU_OPERATOR_CHART" \
    --version "$GPU_OPERATOR_VERSION" -n "$GPU_OPERATOR_NAMESPACE" --create-namespace \
    -f "$WORKFLOW_ROOT/templates/gpu-operator-values.yaml" \
    --set driver.enabled="$GPU_OPERATOR_DRIVER_ENABLED" --wait --timeout 15m 2>&1 | tee -a "$logf"

  # KCM first — it provides the Sveltos CRDs that KOF depends on.
  log "installing k0rdent / KCM"
  run hlm upgrade --install kcm "$KCM_CHART" --version "$KCM_VERSION" \
    -n "$KCM_NAMESPACE" --create-namespace --wait --timeout 15m 2>&1 | tee -a "$logf"
  wait_for 300 "Sveltos CRD present (KOF prerequisite)" \
    kc get crd clusterprofiles.config.projectsveltos.io
  _trim_kcm_providers

  # KOF (single umbrella release): operators + mothership + storage + collectors
  # on this one cluster. Sub-chart toggles live in templates/kof-values.yaml
  # (kof-regional/kof-child off; kof-storage/kof-collectors on; 1h retention).
  log "installing KOF (operators + mothership + storage + collectors)"
  run hlm upgrade --install kof "$KOF_CHART" --version "$KOF_VERSION" \
    -n "$KOF_NAMESPACE" --create-namespace --reset-values \
    -f "$WORKFLOW_ROOT/templates/kof-values.yaml" --wait --timeout 20m 2>&1 | tee -a "$logf"
  # The umbrella only creates the HelmRelease CRs; wait until they reconcile Ready.
  _wait_kof_helmreleases "$TIMEOUT_KOF"

  log "installing exalsius-operator"
  run hlm upgrade --install exalsius-operator "$EXALSIUS_OPERATOR_CHART" \
    --version "$EXALSIUS_OPERATOR_VERSION" -n "$KCM_NAMESPACE" --wait --timeout 10m 2>&1 | tee -a "$logf"

  wait_for 300 "exalsius CRDs registered" \
    kc get crd workspacedeployments.workspaces.exalsius.ai workspaceclasses.workspaces.exalsius.ai

  # Hugging Face token secret consumed by the WorkspaceDeployment.
  log "creating HF token secret"
  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    kc -n "$WORKSPACE_NAMESPACE" create secret generic "$HF_SECRET_NAME" \
      --from-literal=token="$HF_TOKEN" --dry-run=client -o yaml | kc apply -f -
  fi

  # Adopt the cluster into k0rdent.
  log "adopting cluster into k0rdent"
  _create_adoption_kubeconfig_secret
  render "$WORKFLOW_ROOT/templates/adopt-cluster.yaml.tmpl" "$RUN_DIR/manifests/adopt-cluster.yaml"
  run kc apply -f "$RUN_DIR/manifests/adopt-cluster.yaml" 2>&1 | tee -a "$logf"
  wait_for "$TIMEOUT_PREPARE" "ClusterDeployment/$CLUSTER_NAME Ready" \
    bash -c 'KUBECONFIG="'"$KUBECONFIG_OUT"'" kubectl -n "'"$KCM_NAMESPACE"'" get clusterdeployment "'"$CLUSTER_NAME"'" -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -q True'

  # Workspace catalog, in dependency order: the Flux HelmRepository first, then
  # the ServiceTemplates that source it, then the WorkspaceClass that uses them.
  log "registering workspace catalog (HelmRepository -> ServiceTemplates -> WorkspaceClass)"
  run kc apply -f "$WORKFLOW_ROOT/templates/workspace-helmrepository.yaml" 2>&1 | tee -a "$logf"
  run kc apply -f "$WORKFLOW_ROOT/templates/workspace-servicetemplates.yaml" 2>&1 | tee -a "$logf"
  # Let k0rdent/Flux reconcile the ServiceTemplates before the class references them.
  wait_for 300 "ServiceTemplate llm-d-model-0-3-0 valid" \
    bash -c 'KUBECONFIG="'"$KUBECONFIG_OUT"'" kubectl -n "'"$KCM_NAMESPACE"'" get servicetemplate llm-d-model-0-3-0 -o jsonpath="{.status.valid}" | grep -q true' || \
    warn "ServiceTemplate not reported valid yet"
  run kc apply -f "$WORKFLOW_ROOT/templates/workspace-class.yaml" 2>&1 | tee -a "$logf"

  # Wait until GPUs are advertised as schedulable.
  wait_for "$TIMEOUT_PREPARE" "GPUs schedulable (nvidia.com/gpu allocatable)" \
    bash -c 'KUBECONFIG="'"$KUBECONFIG_OUT"'" kubectl get nodes -o jsonpath="{.items[*].status.allocatable.nvidia\.com/gpu}" | grep -qE "[1-9]"'

  info "cluster prepared"
}
