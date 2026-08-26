#!/usr/bin/env bash
# Phase 5 — Collect. Snapshot the required metric series from Prometheus, gather
# logs, and write a human-readable run report. Defines phase_collect.

# The minimum required series. Presence + non-emptiness is the telemetry
# acceptance gate; the values are recorded, not gated.
REQUIRED_METRICS=(
  'DCGM_FI_DEV_GPU_UTIL'
  'DCGM_FI_DEV_FB_USED'
  'DCGM_FI_DEV_POWER_USAGE'
  'vllm:num_requests_running'
  'vllm:time_to_first_token_seconds_count'
  'vllm:e2e_request_latency_seconds_count'
  'vllm:generation_tokens_total'
  'vllm:kv_cache_usage_perc'   # renamed from vllm:gpu_cache_usage_perc in vLLM ~0.9+
)

phase_collect() {
  export KUBECONFIG="$KUBECONFIG_OUT"
  # Query VictoriaMetrics (KOF storage) via the vmselect Service.
  local vm_svc="$VM_QUERY_SERVICE" local_port=18428
  local base="http://127.0.0.1:${local_port}"

  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    kubectl -n "$KOF_NAMESPACE" port-forward "svc/$vm_svc" "${local_port}:${VM_QUERY_PORT}" \
      >>"$RUN_DIR/collect.log" 2>&1 &
    local pf_pid=$!
    # shellcheck disable=SC2064
    trap "kill $pf_pid 2>/dev/null || true" RETURN
    wait_for 60 "VictoriaMetrics query API up" bash -c "curl -sf ${base}/health -o /dev/null" || \
      warn "VictoriaMetrics not reachable; metric snapshot may be empty"
  fi

  local present=() missing=() m
  for m in "${REQUIRED_METRICS[@]}"; do
    local safe; safe="$(printf '%s' "$m" | tr ':/' '__')"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then present+=("$m"); continue; fi
    curl -sf --data-urlencode "query=$m" "${base}${VM_QUERY_PATH}" \
      -o "$RUN_DIR/metrics/${safe}.json" 2>/dev/null || true
    if [[ "$(jq -r '.data.result | length' "$RUN_DIR/metrics/${safe}.json" 2>/dev/null || echo 0)" -gt 0 ]]; then
      present+=("$m")
    else
      missing+=("$m")
    fi
  done
  printf '%s\n' "${present[@]:-}" > "$RUN_DIR/metrics/_present.txt"
  printf '%s\n' "${missing[@]:-}" > "$RUN_DIR/metrics/_missing.txt"
  [[ ${#missing[@]} -eq 0 ]] && info "all required metric series present" \
    || warn "missing metric series: ${missing[*]}"

  # Deployment timings from the phase ledger.
  cp -f "$RUN_DIR/phases.tsv" "$RUN_DIR/metrics/deployment.tsv" 2>/dev/null || true

  # Gather workspace + operator logs (best effort).
  kc -n "$WORKSPACE_NAMESPACE" describe workspacedeployment "$WORKSPACE_NAME" \
    > "$RUN_DIR/results/workspace-describe.txt" 2>/dev/null || true

  # Write the report first (so the artifact exists even on failure), then enforce
  # the telemetry acceptance gate: presence of all required series is a hard
  # requirement (README §Acceptance), so a gap fails the run — not just a warning.
  _write_report "${#missing[@]}"
  info "collection complete -> ${RUN_DIR#"$WORKFLOW_ROOT"/}/run-report.md"
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "telemetry acceptance not met: ${#missing[@]} required metric series missing (${missing[*]})"
  fi
}

_write_report() {
  local n_missing="$1" report="$RUN_DIR/run-report.md"
  local func_ok="unknown"
  # Functional probe = raw OpenAI response; pass iff a non-empty completion.
  if [[ -f "$RUN_DIR/results/functional.json" ]]; then
    if jq -e '.choices[0].message.content | select(length>0)' \
         "$RUN_DIR/results/functional.json" >/dev/null 2>&1; then func_ok="pass"; else func_ok="FAIL"; fi
  fi
  # aiperf export. Verified against aiperf's metrics_json_exporter: every metric is
  # an object {unit, avg, p50, p90, p99, ...}; latencies are in MILLISECONDS,
  # throughput in tokens/sec (or requests/sec). _aiperf_metric renders "<value> <unit>"
  # (2 decimals), or "n/a" when the series is absent.
  local aj="$RUN_DIR/results/aiperf.json"
  local tput rps ttft_p50 ttft_p90 lat_p50 lat_p90 itl_p50 osl
  tput="$(_aiperf_metric "$aj" '.output_token_throughput' avg)"
  rps="$(_aiperf_metric  "$aj" '.request_throughput'      avg)"
  ttft_p50="$(_aiperf_metric "$aj" '.time_to_first_token' p50)"
  ttft_p90="$(_aiperf_metric "$aj" '.time_to_first_token' p90)"
  lat_p50="$(_aiperf_metric  "$aj" '.request_latency'     p50)"
  lat_p90="$(_aiperf_metric  "$aj" '.request_latency'     p90)"
  itl_p50="$(_aiperf_metric  "$aj" '.inter_token_latency' p50)"
  osl="$(_aiperf_metric      "$aj" '.output_sequence_length' avg)"
  {
    echo "# Benchmark run report — ${SCENARIO}"
    echo
    echo "- **Scenario:** ${SCENARIO} (${WORKSPACE_NAME})"
    echo "- **Cluster:** ${CLUSTER_NAME}  ·  **Model:** ${MODEL_ID}"
    echo "- **Topology:** replicas=${DECODE_REPLICAS} (ms.decode.replicas), gpu/replica=${GPU_COUNT_PER_REPLICA} (ms.decode.parallelism.tensor)"
    echo "- **Load tool:** aiperf (in-cluster Job)  ·  **Run dir:** \`${RUN_DIR#"$WORKFLOW_ROOT"/}\`"
    echo
    echo "## Phases"
    echo '| time (UTC) | phase | status |'
    echo '|---|---|---|'
    [[ -f "$RUN_DIR/phases.tsv" ]] && awk -F'\t' '{printf "| %s | %s | %s |\n",$1,$2,$3}' "$RUN_DIR/phases.tsv"
    echo
    echo "## Functional acceptance"
    echo "- Functional probe (non-empty completion): **${func_ok}**"
    echo "- aiperf load export captured: **$( [[ -s "$RUN_DIR/results/aiperf.json" ]] && echo yes || echo no )**"
    echo "- Required metric series missing: **${n_missing}** (must be 0)"
    echo
    echo "## Recorded performance (aiperf; reported, not gated)"
    echo "- Output token throughput: ${tput}"
    echo "- Request throughput: ${rps}"
    echo "- Time to first token (TTFT): p50 ${ttft_p50} · p90 ${ttft_p90}"
    echo "- Request latency (end-to-end): p50 ${lat_p50} · p90 ${lat_p90}"
    echo "- Inter-token latency: p50 ${itl_p50}"
    echo "- Output sequence length: ${osl}"
    echo
    echo "_Metric snapshots in \`metrics/\`; aiperf export in \`results/aiperf.json\`._"
  } > "$report"
}

# _aiperf_metric <file> <jq-path-to-metric-object> <field> -> "<value> <unit>" | "n/a".
# aiperf exports each metric as {"unit": "...", "avg": .., "p50": .., ...}; we pull
# one field and pair it with the metric's own unit, rounded to 2 decimals.
_aiperf_metric() {
  local file="$1" path="$2" field="$3"
  [[ -s "$file" ]] || { echo "n/a"; return; }
  jq -r --arg f "$field" '
    def r: (.*100|round)/100;
    '"$path"' as $m
    | ($m[$f]) as $v
    | if $v == null then "n/a" else "\($v|r) \($m.unit // "")" | rtrimstr(" ") end
  ' "$file" 2>/dev/null || echo "n/a"
}
