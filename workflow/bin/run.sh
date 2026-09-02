#!/usr/bin/env bash
# =============================================================================
# End-to-end benchmark workflow orchestrator.
#
#   run.sh <scenario> [options]
#
#   <scenario>            s1 | s2 | s3
#
# Options:
#   --from <phase>        start at this phase (default: preflight)
#   --to   <phase>        stop after this phase (default: cleanup)
#   --only <phase>        run exactly one phase
#   --run-id <id>         run directory name under runs/<scenario>/ (else prompts / RUN_ID)
#   --ssh-user <name>     SSH username for the nodes (else prompts / SSH_USERNAME)
#   --ssh-key <path>      SSH private key for the nodes (else prompts / SSH_KEY_PATH)
#   --keep               do not run cleanup (leave the cluster up)
#   --dry-run            print commands without executing
#   -h|--help            show this help
#
# Phases, in order:
#   preflight bootstrap prepare deploy execute collect cleanup
#
# The whole run shares one artifact directory: runs/<scenario>/<UTC-timestamp>/.
# Reproducibility = two consecutive clean runs both passing.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WORKFLOW_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=../lib/common.sh
source "$WORKFLOW_ROOT/lib/common.sh"
# shellcheck source=../lib/render.sh
source "$WORKFLOW_ROOT/lib/render.sh"

PHASES=(preflight bootstrap prepare deploy execute collect cleanup)

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# --- argument parsing --------------------------------------------------------
[[ $# -ge 1 ]] || usage 1
SCENARIO_ARG="$1"; shift
FROM="preflight"; TO="cleanup"; ONLY=""; KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2;;
    --to)   TO="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --run-id) export RUN_ID="$2"; shift 2;;
    --ssh-user) export SSH_USERNAME="$2"; shift 2;;
    --ssh-key) export SSH_KEY_PATH="$2"; shift 2;;
    --keep) KEEP=1; shift;;
    --dry-run) export DRY_RUN=1; shift;;
    -h|--help) usage 0;;
    *) die "unknown option: $1";;
  esac
done

case "$SCENARIO_ARG" in
  s1|s2|s3) ;;
  *) die "scenario must be one of: s1 s2 s3 (got '$SCENARIO_ARG')";;
esac

# --- load config, resolve the phase range -----------------------------------
load_config "$SCENARIO_ARG"

declare -A IDX; for i in "${!PHASES[@]}"; do IDX[${PHASES[$i]}]=$i; done
[[ -n "${IDX[$FROM]:-}" ]] || die "unknown --from phase: $FROM"
[[ -n "${IDX[$TO]:-}"   ]] || die "unknown --to phase: $TO"
if [[ -n "$ONLY" ]]; then
  [[ -n "${IDX[$ONLY]:-}" ]] || die "unknown --only phase: $ONLY"
  FROM="$ONLY"; TO="$ONLY"
fi
start=${IDX[$FROM]}; stop=${IDX[$TO]}

# --- establish the run directory --------------------------------------------
# A cleanup-only invocation reuses an existing run dir (must not be blocked by
# the "already exists" guard); anything that provisions is a fresh run.
resolve_run_id
REUSE=""
if (( start == stop )) && [[ "${PHASES[$start]}" == "cleanup" ]]; then REUSE="reuse"; fi
init_run_dir "$REUSE"
log "scenario=$SCENARIO cluster=$CLUSTER_NAME model=$MODEL_ID run=${RUN_ID} dir=${RUN_DIR#"$WORKFLOW_ROOT"/}"

# Fresh runs start a clean ledger + config snapshot; reuse (cleanup) appends.
if [[ "$REUSE" != "reuse" ]]; then
  : > "$RUN_DIR/phases.tsv"
  { set -o posix; set | grep -E '^(SCENARIO|RUN_ID|CLUSTER_NAME|WORKSPACE_NAME|MODEL_ID|NODE_ENDPOINTS|SSH_USERNAME|EXPECTED_NODE_COUNT|REPLICAS|GPU_COUNT_PER_REPLICA|NODES_PER_REPLICA|WORKSPACE_CPU|GPU_VENDOR|WORKSPACE_CLASS|K0S_VERSION|KCM_VERSION|EXALSIUS_OPERATOR_VERSION|GPU_OPERATOR_VERSION|KOF_VERSION|AIPERF_IMAGE|LOAD_)' ; } > "$RUN_DIR/config.env" || true
fi

# --- load phase functions ----------------------------------------------------
for f in "$WORKFLOW_ROOT"/bin/[0-9][0-9]-*.sh; do source "$f"; done

# --- execute -----------------------------------------------------------------
# Phases are called STANDALONE (not in an `if`) so that `set -e` stays active
# inside them — any un-guarded command failure aborts the phase immediately.
# Such a failure (or an explicit die) exits the script and fires the EXIT trap
# below, which records the failure and tears the cluster down.
CURRENT_PHASE=""
_on_exit() {
  local rc=$?
  [[ $rc -eq 0 ]] && return 0
  [[ -n "${_CLEANING:-}" ]] && return "$rc"   # guard against recursion via cleanup
  _CLEANING=1
  err "run FAILED during phase '${CURRENT_PHASE:-setup}' (exit $rc)"
  [[ -n "${CURRENT_PHASE:-}" ]] && record_phase "${CURRENT_PHASE}" FAILED
  if [[ $KEEP -eq 0 && -n "${CURRENT_PHASE:-}" && "${CURRENT_PHASE}" != "cleanup" ]]; then
    warn "attempting cleanup after failure"
    phase_cleanup || err "cleanup after failure also failed"
  fi
  log "run failed: artifacts ${RUN_DIR#"$WORKFLOW_ROOT"/}"
}
trap _on_exit EXIT

for i in "${!PHASES[@]}"; do
  (( i >= start && i <= stop )) || continue
  p="${PHASES[$i]}"
  if [[ "$p" == "cleanup" && $KEEP -eq 1 ]]; then
    warn "skipping cleanup (--keep): cluster '$CLUSTER_NAME' left running"
    record_phase cleanup skipped
    continue
  fi
  CURRENT_PHASE="$p"
  log "=== phase: $p ==="
  "phase_${p}"                # standalone → set -e / die aborts into _on_exit
  record_phase "$p" ok
done

CURRENT_PHASE=""             # clean finish: EXIT trap sees rc=0 and no-ops
log "run complete: artifacts ${RUN_DIR#"$WORKFLOW_ROOT"/}"
exit 0
