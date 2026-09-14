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
  _snapshot_pre_load_counters "$logf"
  _aiperf_load "$ns" "$logf"
  info "execution complete"
}

# Gate the probe on real readiness: the gateway must be up, every serving pod
# must be Ready, AND the endpoint-picker must have actually discovered every
# replica through the InferencePool before we send traffic. In workspace-hub
# 1.0.0 the workload is a LeaderWorkerSet; only the leader (worker-index 0) runs
# the API server, so the serving pods are the leaders. We wait for ALL of them —
# model copies = REPLICAS / NODES_PER_REPLICA (S1:1, S2:2, S3:1) — so a
# replicated run only starts load once every replica can receive it (A2.2).
_wait_endpoint_ready() {
  local logf="$1"
  local expected=$(( ${REPLICAS:-1} / ${NODES_PER_REPLICA:-1} ))
  (( expected >= 1 )) || expected=1
  wait_for 300 "gateway ${ENDPOINT_SERVICE} (${ENDPOINT_NAMESPACE}) has endpoints" \
    svc_has_endpoints "$ENDPOINT_NAMESPACE" "$ENDPOINT_SERVICE"
  wait_for "${TIMEOUT_WORKSPACE:-1500}" "${expected} model-server leader(s) Ready in ${WORKSPACE_SERVICE_NAMESPACE}" \
    bash -c 'KUBECONFIG="'"$KUBECONFIG_OUT"'" c=$(kubectl -n "'"$WORKSPACE_SERVICE_NAMESPACE"'" get pod -l llm-d.ai/inference-serving=true,leaderworkerset.sigs.k8s.io/worker-index=0 -o jsonpath="{range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}{end}" 2>/dev/null | grep -cx True); [ "${c:-0}" -ge '"$expected"' ]'
  info "gateway up + ${expected} model-server leader(s) serving"
  _wait_epp_pool_ready "$expected" "$logf"
}

# Pod Ready does not mean the EPP has discovered the pod through the
# InferencePool yet — the EPP watches Pods by label selector on its own
# reconcile loop, and InferencePool's status only tracks Gateway-attachment
# conditions (Accepted/ResolvedRefs), never endpoint discovery. Without this
# gate, aiperf could start while the EPP's routing table still only has one
# replica, silently concentrating all load on it (the failure this PR's own
# routing-profile investigation hit). Gate on the EPP's own
# inference_pool_ready_pods gauge instead — scraped by the router subchart's
# own ServiceMonitor into the same VictoriaMetrics the collect phase queries.
_wait_epp_pool_ready() {
  local expected="$1" logf="$2"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  vm_query_start "$logf"
  # shellcheck disable=SC2064
  trap "vm_query_stop" RETURN
  local timeout="${EPP_READY_CHECK_TIMEOUT:-180}"
  local deadline=$(( $(date +%s) + timeout )) val
  log "waiting (≤${timeout}s) for the EPP to discover ${expected} backend endpoint(s) (inference_pool_ready_pods)"
  while :; do
    val="$(vm_query_scalar 'sum(inference_pool_ready_pods)')"
    if [[ -n "$val" ]] && awk -v v="$val" -v e="$expected" 'BEGIN{exit !(v>=e)}'; then
      info "EPP reports ${val} ready pool endpoint(s)"
      return 0
    fi
    (( $(date +%s) < deadline )) || \
      die "EPP never reported ${expected} ready pool endpoint(s) within ${timeout}s (inference_pool_ready_pods last read: ${val:-none}) — refusing to start aiperf before the endpoint-picker can route to every replica"
    sleep 5
  done
}

# Snapshot vllm:generation_tokens_total per pod right before aiperf launches, so
# the collect phase can require a positive DELTA over the load window (A2.2)
# rather than trusting the post-run cumulative value, which the functional
# probe just above already perturbed on whichever replica the gateway routed it
# to. Consumed by 50-collect.sh's _check_replica_traffic.
_snapshot_pre_load_counters() {
  local logf="$1" out="$RUN_DIR/metrics/_pre_load_vllm_generation_tokens_total.json"
  [[ "${DRY_RUN:-0}" == "1" ]] && { : > "$out"; return 0; }
  vm_query_start "$logf"
  vm_query_json 'vllm:generation_tokens_total' > "$out" 2>/dev/null || true
  vm_query_stop
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
