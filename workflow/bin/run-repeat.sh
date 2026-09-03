#!/usr/bin/env bash
# Run a scenario end-to-end N times consecutively — the reproducibility check
# (T3.2/T4.2/T5.2 require at least two consecutive successful runs).
#
#   run-repeat.sh <scenario> <count> [extra run.sh flags...]
#
# Each iteration is a full preflight -> cleanup cycle with a distinct run id
# (<base>-run-<i>, base = RUN_ID_BASE or the scenario). Cleanup returns the nodes
# to bare, so the SAME NODE_ENDPOINTS are reused across iterations. Aborts the
# moment any run fails (a passing sequence means every run passed from a clean
# state). Each run's artifacts are sanitized in place by the cleanup phase.
#
# Inputs must be preset in the environment (there is no TTY to prompt between
# runs): NODE_ENDPOINTS, SSH_USERNAME, SSH_KEY_PATH, HF_TOKEN. The Makefile's
# docker path provides all of these.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scenario="${1:?usage: run-repeat.sh <scenario> <count> [flags]}"; shift
count="${1:?usage: run-repeat.sh <scenario> <count> [flags]}"; shift
[[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || { echo "run-repeat: count must be a positive integer" >&2; exit 1; }

# Fail fast if a required input is unset — we cannot prompt between consecutive runs.
missing=()
for v in NODE_ENDPOINTS SSH_USERNAME SSH_KEY_PATH HF_TOKEN; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if ((${#missing[@]})); then
  echo "run-repeat: these inputs must be preset for a non-interactive sequence: ${missing[*]}" >&2
  exit 1
fi

base="${RUN_ID_BASE:-$scenario}"
for i in $(seq 1 "$count"); do
  rid="${base}-run-${i}"
  echo "==================================================================="
  echo "== consecutive run ${i}/${count}: scenario=${scenario} run-id=${rid}"
  echo "==================================================================="
  if ! "$HERE/run.sh" "$scenario" --run-id "$rid" "$@"; then
    echo "!! run ${i}/${count} (${rid}) FAILED — aborting the consecutive sequence" >&2
    exit 1
  fi
done

echo "== all ${count} consecutive runs of ${scenario} passed (${base}-run-1..${count}) =="
