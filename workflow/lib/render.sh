#!/usr/bin/env bash
# Template rendering helpers. Sourced by phase scripts.
# We use envsubst with an explicit allow-list of variables so that any stray
# `$` in the templates (rare in our YAML) is left untouched.

# render <template> <output> -- substitutes ${VARS} listed in RENDER_VARS.
render() {
  local tmpl="$1" out="$2"
  [[ -f "$tmpl" ]] || die "template not found: $tmpl"
  # Build the "$VAR $VAR ..." allow-list envsubst expects.
  local allow="" v
  for v in $RENDER_VARS; do allow+="\${$v} "; done
  envsubst "$allow" < "$tmpl" > "$out"
  info "rendered $(basename "$tmpl") -> ${out#"$WORKFLOW_ROOT"/}"
}

# The set of variables the templates may reference. Keep in sync with config.
RENDER_VARS="CLUSTER_NAME KCM_NAMESPACE WORKSPACE_NAMESPACE WORKSPACE_SERVICE_NAMESPACE WORKSPACE_NAME \
WORKSPACE_CLASS MODEL_ID HF_TOKEN HF_SECRET_NAME GPU_COUNT_PER_REPLICA \
REPLICAS NODES_PER_REPLICA WORKSPACE_CPU GPU_VENDOR EPP_PLUGINS_CONFIG ADOPTED_CLUSTER_TEMPLATE \
CREDENTIAL_NAME KUBECONFIG_SECRET_NAME KOF_NAMESPACE \
AIPERF_IMAGE AIPERF_PIP_SPEC AIPERF_CPU_REQUEST AIPERF_MEM_REQUEST \
ENDPOINT_SERVICE ENDPOINT_NAMESPACE ENDPOINT_PORT MODEL_HEADER_NAME \
LOAD_CONCURRENCY LOAD_N_PROMPTS LOAD_INPUT_TOKENS LOAD_OUTPUT_TOKENS \
LOAD_WARMUP_PROMPTS AIPERF_MODEL_READY_TIMEOUT AIPERF_REQUEST_TIMEOUT"
export RENDER_VARS
