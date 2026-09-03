#!/usr/bin/env bash
# Sanitize a run directory's artifacts (see lib/sanitize.sh for exactly what is
# redacted). The workflow already sanitizes each run IN PLACE at the end of the
# cleanup phase, so this is mostly for re-sanitizing or for producing a separate
# copy. Idempotent.
#
#   sanitize-run.sh <run-dir>            # sanitize in place
#   sanitize-run.sh <src-run-dir> <dst>  # sanitize a COPY at <dst>, leaving <src> untouched
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/sanitize.sh
source "$HERE/../lib/sanitize.sh"

src="${1:?usage: sanitize-run.sh <run-dir> | <src-run-dir> <dst>}"
dst="${2:-}"

if [[ -z "$dst" ]]; then
  [[ -d "$src" ]] || { echo "sanitize-run: no such run dir: $src" >&2; exit 1; }
  sanitize_run_dir "$src"
  echo "sanitize-run: sanitized in place: $src"
else
  [[ -d "$src" ]] || { echo "sanitize-run: no such run dir: $src" >&2; exit 1; }
  # cp WITHOUT preserving ownership: run artifacts are written by the in-container
  # root user, so a non-root host user cannot chown the copy to root (cp -a would
  # fail). The copy is owned by the caller, so the in-place scrub below can write it.
  rm -rf "$dst"; mkdir -p "$(dirname "$dst")"; cp -r --preserve=mode,timestamps "$src" "$dst"
  sanitize_run_dir "$dst"
  echo "sanitize-run: $src -> $dst (sanitized copy)"
fi
