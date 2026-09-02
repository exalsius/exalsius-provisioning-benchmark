#!/usr/bin/env bash
# Phase 4 — Execute. Run the standard workload entirely in-cluster:
#   - a functional probe (one deterministic request via an ephemeral curl pod)
#   - a load probe (aiperf as a Kubernetes Job hitting the Service over cluster DNS)
# Defines phase_execute.

CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"

phase_execute() {
  local logf="$RUN_DIR/load.log"; : > "$logf"
  export KUBECONFIG="$KUBECONFIG_OUT"

  # shellcheck disable=SC1090
  [[ -f "$RUN_DIR/endpoint.env" ]] && source "$RUN_DIR/endpoint.env"
  export ENDPOINT_SERVICE="${ENDPOINT_SERVICE:-UNKNOWN}"
  export ENDPOINT_PORT="${ENDPOINT_PORT:-80}"
  [[ "$ENDPOINT_SERVICE" == "UNKNOWN" ]] && die "no endpoint Service known (see deploy phase / endpoint.env)"
  export ENDPOINT_NAMESPACE="${ENDPOINT_NAMESPACE:-default}"
  local ns="$ENDPOINT_NAMESPACE"
  local svc_url="http://${ENDPOINT_SERVICE}.${ns}.svc:${ENDPOINT_PORT}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    render "$WORKFLOW_ROOT/templates/aiperf-job.yaml.tmpl" "$RUN_DIR/manifests/aiperf-job.yaml"
    info "[dry-run] would wait for endpoints, then run functional probe + aiperf against $svc_url"
    return 0
  fi

  _wait_endpoint_ready "$logf"     # gateway + workspace backend must be serving first
  _functional_probe "$ns" "$svc_url" "$logf"
  _aiperf_load "$ns" "$logf"
  info "execution complete"
}

# Gate the probe on real readiness: the gateway must be up AND the model's
# serving pod must be Ready before we send traffic. In workspace-hub 1.0.0 the
# workload is a LeaderWorkerSet; only the leader (worker-index 0) runs the API
# server, so we wait on the serving leader (label-selected, release-independent).
_wait_endpoint_ready() {
  local logf="$1"
  wait_for 300 "gateway ${ENDPOINT_SERVICE} (${ENDPOINT_NAMESPACE}) has endpoints" \
    svc_has_endpoints "$ENDPOINT_NAMESPACE" "$ENDPOINT_SERVICE"
  wait_for "${TIMEOUT_WORKSPACE:-1500}" "model server leader Ready in ${WORKSPACE_SERVICE_NAMESPACE}" \
    bash -c 'KUBECONFIG="'"$KUBECONFIG_OUT"'" kubectl -n "'"$WORKSPACE_SERVICE_NAMESPACE"'" get pod -l llm-d.ai/inference-serving=true,leaderworkerset.sigs.k8s.io/worker-index=0 -o jsonpath="{.items[*].status.conditions[?(@.type==\"Ready\")].status}" 2>/dev/null | grep -q True'
  info "gateway up + model server leader serving"
}

# Gate: a deterministic request via an ephemeral in-cluster curl pod, RETRIED
# until the gateway returns a valid completion for THIS model (routing + model
# load can lag workspace-ready). If it never succeeds we die — we must not run
# aiperf against a non-serving endpoint (the functionality gate).
_functional_probe() {
  local ns="$1" svc_url="$2" logf="$3"
  local timeout="${TIMEOUT_FUNCPROBE:-600}" attempt=0
  local deadline=$(( $(date +%s) + timeout ))
  local body
  body=$(cat <<JSON
{"model":"${MODEL_ID}","messages":[{"role":"user","content":"In one sentence, what is Kubernetes?"}],"temperature":0,"max_tokens":${LOAD_OUTPUT_TOKENS}}
JSON
)
  log "functional probe against $svc_url (model $MODEL_ID; ≤${timeout}s)"
  while :; do
    attempt=$((attempt + 1))
    kubectl -n "$ns" run "funcprobe-${WORKSPACE_NAME}-${attempt}" --rm -i --restart=Never \
      --image="$CURL_IMAGE" --quiet -- \
      curl -sS -m 60 -X POST "${svc_url}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -H "${MODEL_HEADER_NAME}: ${MODEL_ID}" -d "$body" \
      > "$RUN_DIR/results/functional.json" 2>>"$logf" || true
    if jq -e '.choices[0].message.content | select(length>0)' \
         "$RUN_DIR/results/functional.json" >/dev/null 2>&1; then
      info "functional probe passed (valid completion for $MODEL_ID)"
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      err "last functional-probe response:"; cat "$RUN_DIR/results/functional.json" >&2 2>/dev/null || true
      die "functional probe never returned a valid completion for $MODEL_ID at $svc_url"
    fi
    log "  no valid completion yet (attempt $attempt); retrying in 15s"
    sleep 15
  done
}

# aiperf load test as a Kubernetes Job; retrieve the JSON export from the pod log.
_aiperf_load() {
  local ns="$1" logf="$2"
  # aiperf reads the HF token (tokenizer download) from a Secret in its namespace.
  resolve_hf_token
  kubectl -n "$ns" create secret generic "$HF_SECRET_NAME" \
    --from-literal=token="$HF_TOKEN" --dry-run=client -o yaml | kubectl -n "$ns" apply -f - >/dev/null 2>&1 || \
    warn "could not create HF secret in $ns"
  render "$WORKFLOW_ROOT/templates/aiperf-job.yaml.tmpl" "$RUN_DIR/manifests/aiperf-job.yaml"
  local job="aiperf-${WORKSPACE_NAME}"
  kubectl -n "$ns" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true

  log "launching aiperf Job (${LOAD_N_PROMPTS} req @ concurrency ${LOAD_CONCURRENCY})"
  run kubectl -n "$ns" apply -f "$RUN_DIR/manifests/aiperf-job.yaml" 2>&1 | tee -a "$logf"

  # Block until the Job reaches a terminal state — whichever of complete/failed
  # fires first (with backoffLimit 0, a pod error surfaces as condition=failed).
  kubectl -n "$ns" wait --for=condition=complete "job/$job" --timeout=1800s >>"$logf" 2>&1 &
  local w1=$!
  kubectl -n "$ns" wait --for=condition=failed "job/$job" --timeout=1800s >>"$logf" 2>&1 &
  local w2=$!
  wait -n "$w1" "$w2" 2>/dev/null || true
  kill "$w1" "$w2" 2>/dev/null || true

  # Always capture the full pod log (diagnostics + JSON extraction source).
  kubectl -n "$ns" logs "job/$job" > "$RUN_DIR/results/aiperf.log" 2>>"$logf" || true

  # The load probe is a functional acceptance artifact: a failed Job (or a Job
  # that never reached success) is a hard failure, not a warning.
  local succeeded failed
  succeeded="$(kubectl -n "$ns" get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)"
  failed="$(kubectl -n "$ns" get job "$job" -o jsonpath='{.status.failed}' 2>/dev/null || echo 0)"
  if [[ "${succeeded:-0}" != "1" ]]; then
    err "aiperf Job did not complete (succeeded=${succeeded:-0} failed=${failed:-0}); last log lines:"
    tail -n 40 "$RUN_DIR/results/aiperf.log" >&2 2>/dev/null || true
    die "aiperf load generation failed (see results/aiperf.log)"
  fi

  # Extract + validate the base64 JSON export; a missing/invalid export fails.
  if sed -n '/=====AIPERF_JSON_BEGIN=====/,/=====AIPERF_JSON_END=====/p' \
        "$RUN_DIR/results/aiperf.log" | sed '1d;$d' | base64 -d \
        > "$RUN_DIR/results/aiperf.json" 2>/dev/null && \
     [[ -s "$RUN_DIR/results/aiperf.json" ]] && \
     jq -e . "$RUN_DIR/results/aiperf.json" >/dev/null 2>&1; then
    info "aiperf results captured -> results/aiperf.json"
  else
    die "aiperf JSON export missing or invalid (see results/aiperf.log)"
  fi
}
