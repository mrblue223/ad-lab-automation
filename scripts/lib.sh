#!/usr/bin/env bash
# shellcheck disable=SC2034  # REPO_ROOT/TFVARS/... are used by the sourcing scripts
# Shared helpers for deploy-azure.sh, scripts/setup.sh and scripts/azure-myip.sh.
# Sourced, not executed. Contains no user-specific values.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="$REPO_ROOT/terraform/terraform.tfvars"        # gitignored, mode 0600
SECRETS_DIR="$REPO_ROOT/.secrets"                     # gitignored, mode 0700
TS_KEY_FILE="$SECRETS_DIR/tailscale-authkey"          # gitignored, mode 0600

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Print this machine's public IPv4 (first of three services that answers sanely).
detect_ip() {
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    if is_public_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

# True if $1 is a single, globally routable IPv4 address (no CIDR, not private,
# not 0.0.0.0, not documentation/CGNAT/loopback/multicast).
is_public_ipv4() {
  python3 -I -c '
import ipaddress, sys
try:
    ip = ipaddress.IPv4Address(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if ip.is_global and not ip.is_multicast else 1)' "${1:-}"
}

# Azure VM admin password rules: 12-123 chars, 3 of 4 classes.
password_ok() {
  local p=$1 classes=0
  if [ "${#p}" -lt 12 ] || [ "${#p}" -gt 123 ]; then return 1; fi
  [[ $p =~ [a-z] ]] && classes=$((classes + 1))
  [[ $p =~ [A-Z] ]] && classes=$((classes + 1))
  [[ $p =~ [0-9] ]] && classes=$((classes + 1))
  [[ $p =~ [^a-zA-Z0-9] ]] && classes=$((classes + 1))
  [ "$classes" -ge 3 ]
}

# Read one key from the gitignored tfvars (empty if absent). Not for secrets you
# intend to print — callers must not echo admin_password.
tfvars_get() {
  [ -f "$TFVARS" ] || return 0
  python3 -I "$REPO_ROOT/scripts/hclvars.py" get "$TFVARS" "$1"
}

# Refuse to write a file that git would track. Every user-specific value must
# land in a gitignored path.
assert_gitignored() {
  local f
  for f in "$@"; do
    git -C "$REPO_ROOT" check-ignore -q "$f" \
      || die "Refusing to write $f: it is not gitignored. Fix .gitignore first."
    if git -C "$REPO_ROOT" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      die "Refusing to write $f: it is TRACKED by git. Run: git rm --cached '$f'"
    fi
  done
}
