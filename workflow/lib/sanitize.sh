#!/usr/bin/env bash
# In-place run-artifact sanitizer. Sourced by run.sh (called at the end of the
# cleanup phase) and by bin/sanitize-run.sh. Redacts identifying values across
# ALL text files of a run directory and drops the cluster kubeconfig, so the
# recorded artifacts are safe to commit/share. Idempotent.
#
# Redacted (identifiers derived from the run's OWN artifacts):
#   kubeconfig                     -> removed          (admin credentials)
#   Hugging Face tokens (hf_...)   -> REDACTED_HF_TOKEN
#   node public endpoint address   -> NODE_1, NODE_2, ...        (config.env + k0sctl.yaml)
#   node private address           -> NODE_PRIVIP_1, ...         (k0sctl bootstrap log)
#   node hostname (k8s node name)  -> NODE_HOST_1, ...           (k0sctl log + metric Hostname label)
#   SSH username                   -> REDACTED_SSH_USER
#   SSH private-key path           -> REDACTED_SSH_KEY_PATH
# Cluster-internal pod IPs (10.244.x) and hardware ids (GPU UUID, PCI bus) are
# left as-is — not sensitive and useful for interpretation.

_san_cfg_val() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'"; }
_san_esc_search() { printf '%s' "$1" | sed -e 's/[][\.*^$|]/\\&/g'; }

# _san_uniq <values...> -> unique, non-empty, LONGEST first (so a value that is a
# prefix of another is replaced first and cannot corrupt the longer one).
_san_uniq() { printf '%s\n' "$@" | awk 'NF' | sort -u | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-; }

# _san_apply <dir> <sed-expr> — apply a sed expression to every TEXT file (skips binaries).
_san_apply() {
  local dir="$1" expr="$2" f
  while IFS= read -r -d '' f; do
    grep -Iq . "$f" 2>/dev/null || continue
    sed -i "$expr" "$f"
  done < <(find "$dir" -type f -print0)
}

# sanitize_run_dir <run-dir> — scrub the directory in place.
sanitize_run_dir() {
  local dir="${1:?sanitize_run_dir <run-dir>}"
  [[ -d "$dir" ]] || return 0
  rm -f "$dir/kubeconfig"

  local cfg="$dir/config.env" k0s="$dir/manifests/k0sctl.yaml"
  local ssh_user ssh_key endpoints
  ssh_user="$(_san_cfg_val "$cfg" SSH_USERNAME)"
  endpoints="$(_san_cfg_val "$cfg" NODE_ENDPOINTS)"
  if [[ -f "$k0s" ]]; then
    [[ -n "$ssh_user" ]] || ssh_user="$(awk -F'[: ]+' '/user:/{print $3; exit}' "$k0s")"
    ssh_key="$(awk -F'[: ]+' '/keyPath:/{print $3; exit}' "$k0s")"
  fi

  # --- collect identifier sets from the run's own artifacts --------------------
  local -a pub_hosts=() priv_ips=() hostnames=()
  local ep h a ip
  if [[ -n "$endpoints" ]]; then
    local IFS=','
    for ep in $endpoints; do h="${ep%:*}"; h="${h// /}"; [[ -n "$h" ]] && pub_hosts+=("$h"); done
  fi
  if [[ -f "$k0s" ]]; then
    while read -r a; do [[ -n "$a" ]] && pub_hosts+=("$a"); done \
      < <(awk -F'[: ]+' '/address:/{print $3}' "$k0s")
  fi
  # node hostnames: k0sctl "using <name> as hostname" + DCGM "Hostname":"<name>"
  while read -r h; do [[ -n "$h" ]] && hostnames+=("$h"); done \
    < <(grep -rhoE 'using [A-Za-z0-9][A-Za-z0-9._-]* as hostname' "$dir" 2>/dev/null | awk '{print $2}')
  while read -r h; do [[ -n "$h" ]] && hostnames+=("$h"); done \
    < <(grep -rhoE '"Hostname":"[^"]+"' "$dir" 2>/dev/null | sed -E 's/.*"Hostname":"([^"]+)".*/\1/')
  # node private address: k0sctl "discovered <ip> as private address"
  while read -r ip; do [[ -n "$ip" ]] && priv_ips+=("$ip"); done \
    < <(grep -rhoE 'discovered [0-9.]+ as private address' "$dir" 2>/dev/null | awk '{print $2}')

  ((${#pub_hosts[@]})) && mapfile -t pub_hosts < <(_san_uniq "${pub_hosts[@]}")
  ((${#priv_ips[@]}))  && mapfile -t priv_ips  < <(_san_uniq "${priv_ips[@]}")
  ((${#hostnames[@]})) && mapfile -t hostnames < <(_san_uniq "${hostnames[@]}")

  # --- apply redactions --------------------------------------------------------
  _san_apply "$dir" 's|hf_[A-Za-z0-9][A-Za-z0-9]\{15,\}|REDACTED_HF_TOKEN|g'
  local i
  i=1; for h in "${pub_hosts[@]:-}"; do [[ -n "$h" ]] && { _san_apply "$dir" "s|$(_san_esc_search "$h")|NODE_${i}|g"; i=$((i+1)); }; done
  i=1; for h in "${priv_ips[@]:-}";  do [[ -n "$h" ]] && { _san_apply "$dir" "s|$(_san_esc_search "$h")|NODE_PRIVIP_${i}|g"; i=$((i+1)); }; done
  i=1; for h in "${hostnames[@]:-}"; do [[ -n "$h" ]] && { _san_apply "$dir" "s|$(_san_esc_search "$h")|NODE_HOST_${i}|g"; i=$((i+1)); }; done
  [[ -n "$ssh_key"  ]] && _san_apply "$dir" "s|$(_san_esc_search "$ssh_key")|REDACTED_SSH_KEY_PATH|g"
  # SSH user last + word-boundaried, so a common username does not clobber substrings.
  [[ -n "$ssh_user" ]] && _san_apply "$dir" "s|\b$(_san_esc_search "$ssh_user")\b|REDACTED_SSH_USER|g"
  return 0
}
