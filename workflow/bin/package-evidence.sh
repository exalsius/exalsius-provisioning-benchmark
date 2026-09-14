#!/usr/bin/env bash
# Package sanitized run evidence for a scenario into a Git LFS tarball.
#
#   package-evidence.sh <scenario> <run-id-1> [<run-id-2> ...]
#   e.g.  package-evidence.sh s1 s1-run-1 s1-run-2
#
# Each run under workflow/runs/<scenario>/<run-id> is sanitized (see
# sanitize-run.sh) into run-1/, run-2/, ... and tarred to
# docs/evidence/scenario-<n>.tar.gz (tracked by Git LFS via .gitattributes).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$WF/.." && pwd)"

scenario="${1:?usage: package-evidence.sh <scenario> <run-id> [run-id ...]}"; shift
[[ $# -ge 1 ]] || { echo "package-evidence: give at least one run-id" >&2; exit 1; }

num="${scenario#s}"
out="$REPO/docs/evidence/scenario-${num}.tar.gz"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT

n=1
for rid in "$@"; do
  src="$WF/runs/$scenario/$rid"
  [[ -d "$src" ]] || { echo "package-evidence: run dir not found: $src" >&2; exit 1; }
  "$HERE/sanitize-run.sh" "$src" "$stage/run-$n"
  n=$((n+1))
done

mkdir -p "$(dirname "$out")"
tar -C "$stage" -czf "$out" .
echo "package-evidence: wrote ${out#"$REPO"/} ($(du -h "$out" | cut -f1))"
echo "  next: git lfs install && git add ${out#"$REPO"/} && git commit"
