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
  vm_query_start "$RUN_DIR/collect.log"
  # shellcheck disable=SC2064
  trap "vm_query_stop" RETURN

  local present=() missing=() m
  for m in "${REQUIRED_METRICS[@]}"; do
    local safe; safe="$(printf '%s' "$m" | tr ':/' '__')"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then present+=("$m"); continue; fi
    vm_query_json "$m" > "$RUN_DIR/metrics/${safe}.json" 2>/dev/null || true
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

  local ws_ready; ws_ready="$(_check_workspace_ready)"

  local expected_replicas=$(( ${REPLICAS:-1} / ${NODES_PER_REPLICA:-1} ))
  (( expected_replicas >= 1 )) || expected_replicas=1
  local active_replicas; active_replicas="$(_check_replica_traffic "$expected_replicas")"

  # Write the report first (so the artifact exists even on failure), then enforce
  # the hard gates: presence of all required metric series (README §Acceptance), the
  # WorkspaceDeployment reaching Ready/Available, and every replica having actually
  # received traffic during the load window — a gap in any fails the run.
  _write_report "${#missing[@]}" "$ws_ready" "$active_replicas" "$expected_replicas"
  info "collection complete -> ${RUN_DIR#"$WORKFLOW_ROOT"/}/run-report.md"
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "telemetry acceptance not met: ${#missing[@]} required metric series missing (${missing[*]})"
  fi
  if [[ "$ws_ready" != "True" ]]; then
    die "WorkspaceDeployment Ready/Available condition never read True (status: ${ws_ready}) — see results/workspace-describe.txt"
  fi
  if [[ "$active_replicas" == "missing" ]]; then
    die "replica-traffic acceptance not checkable: pre-load or post-load vllm:generation_tokens_total snapshot is missing (see metrics/_pre_load_vllm_generation_tokens_total.json, metrics/vllm_generation_tokens_total.json — expected from 40-execute.sh's _snapshot_pre_load_counters and this phase's own metric snapshot respectively)"
  elif (( active_replicas < expected_replicas )); then
    die "replica-traffic acceptance not met: only ${active_replicas}/${expected_replicas} replica(s) show a positive vllm:generation_tokens_total delta over the aiperf window (see metrics/vllm_generation_tokens_total.json vs metrics/_pre_load_vllm_generation_tokens_total.json)"
  fi
}

# A2.2: verify every replica actually served aiperf traffic, not just that the
# aggregate series is non-empty. A post-run cumulative counter alone can't tell
# "this pod served the load" from "this pod only ever answered the functional
# probe" (which the gateway can route to any one replica) or "this pod has been
# idle since it started" — so compare each pod's vllm:generation_tokens_total
# against the snapshot the execute phase took right before aiperf launched
# (40-execute.sh's _snapshot_pre_load_counters) and require a positive delta.
# Prints the number of replicas with delta > 0, or the literal string "missing"
# if either snapshot is absent (e.g. an aborted execute phase) — kept distinct
# from a genuine 0 so the failure message doesn't read as "traffic imbalanced"
# when the real problem is a missing snapshot. DRY_RUN short-circuits to pass.
_check_replica_traffic() {
  local expected="$1"
  [[ "${DRY_RUN:-0}" == "1" ]] && { echo "$expected"; return 0; }
  local pre="$RUN_DIR/metrics/_pre_load_vllm_generation_tokens_total.json"
  local post="$RUN_DIR/metrics/vllm_generation_tokens_total.json"
  [[ -s "$pre" && -s "$post" ]] || { echo missing; return 0; }
  jq -s '
    (.[0].data.result // []) as $preArr
    | (.[1].data.result // []) as $post
    | ($preArr | map({(.metric.instance): .value[1]}) | add // {}) as $preMap
    | [ $post[] as $p
        | (($p.value[1] | tonumber) - (($preMap[$p.metric.instance] // "0") | tonumber))
      ]
    | map(select(. > 0)) | length
  ' "$pre" "$post" 2>/dev/null || echo 0
}

# Gate on the WorkspaceDeployment's own Ready/Available condition — checked HERE,
# not during deploy-phase sequencing (30-deploy.sh), because that condition can read
# True while the shared llm-d-infra prerequisite is still installing; gating deploy on
# it would have let a run proceed before the model's ServiceSet was even applied. By
# collect time the execute phase has already proven the model serves (leader pod
# Ready + a real functional-probe completion), so the condition should already have
# converged — bounded poll (default 60s) as a safety margin, not a real wait. If it
# still isn't True, that's a genuine inconsistency in the operator's reported status
# and the run fails, per the common spec's acceptance criteria (§7.1).
_check_workspace_ready() {
  [[ "${DRY_RUN:-0}" == "1" ]] && { echo "True"; return 0; }
  local timeout="${WORKSPACE_READY_CHECK_TIMEOUT:-60}"
  local deadline=$(( $(date +%s) + timeout )) status=""
  while :; do
    status="$(kc -n "$WORKSPACE_NAMESPACE" get workspacedeployment "$WORKSPACE_NAME" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ -z "$status" ]] && status="$(kc -n "$WORKSPACE_NAMESPACE" get workspacedeployment "$WORKSPACE_NAME" \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    [[ "$status" == "True" ]] && { echo "True"; return 0; }
    (( $(date +%s) < deadline )) || break
    sleep 5
  done
  echo "${status:-none}"
}

_write_report() {
  local n_missing="$1" ws_ready="${2:-Unknown}" active_replicas="${3:-0}" expected_replicas="${4:-1}"
  local report="$RUN_DIR/run-report.md"
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
    echo "- **Topology:** replicas=${REPLICAS} pods · gpu/pod=${GPU_COUNT_PER_REPLICA} · nodes/replica=${NODES_PER_REPLICA} (tensor-parallel size $((GPU_COUNT_PER_REPLICA * NODES_PER_REPLICA)))"
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
    echo "- WorkspaceDeployment Ready/Available condition: **${ws_ready}** (must be True; checked" \
         "here rather than during deploy-phase sequencing — see" \
         "\`docs/specs/common-experiment-setup.md\` §7.1)"
    echo "- Replicas that received load traffic: **${active_replicas}/${expected_replicas}** (must" \
         "equal expected; per-pod \`vllm:generation_tokens_total\` delta over the aiperf window — A2.2)"
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
