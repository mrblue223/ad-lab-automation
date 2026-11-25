#!/usr/bin/env bash
# =============================================================================
#  setup.sh  (make setup) — interactive, re-runnable pre-deploy configuration
#
#  Collects everything user-specific AT RUNTIME and writes it ONLY to gitignored
#  files. Nothing personal is ever written into a tracked file:
#
#    terraform/terraform.tfvars   access_mode, location, resource_group_name,
#                                 allowed_source_ip, admin_password   (mode 0600)
#    .secrets/tailscale-authkey   Tailscale auth key (tailscale mode)   (mode 0600)
#
#  Re-running updates those files in place (your other tfvars keys are kept)
#  and offers to keep each existing value.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ -t 0 ] || die "setup is interactive — run it from a terminal: make setup"
for bin in python3 curl git; do command -v "$bin" >/dev/null || die "'$bin' not found."; done

# Safety net: refuse to proceed if any target path would be tracked by git.
assert_gitignored "$TFVARS" "$TS_KEY_FILE"

ask() {   # ask "Prompt" "default" -> echoes answer (default on empty)
  local reply
  read -rp "$1${2:+ [$2]}: " reply
  printf '%s' "${reply:-$2}"
}
yes_no() {   # yes_no "Question" Y|N -> 0 for yes
  local def=$2 reply opts="y/N"
  if [ "$def" = Y ]; then opts="Y/n"; fi
  read -rp "$1 [$opts]: " reply
  reply="${reply:-$def}"
  [[ $reply =~ ^[Yy] ]]
}

say "MARVEL.local lab — setup"
echo "Values you enter go ONLY into gitignored files:"
echo "  ${TFVARS#"$REPO_ROOT"/}  and  ${TS_KEY_FILE#"$REPO_ROOT"/}"

CUR_MODE="$(tfvars_get access_mode)"
CUR_LOC="$(tfvars_get location)"
CUR_RG="$(tfvars_get resource_group_name)"
CUR_IP="$(tfvars_get allowed_source_ip)"
HAVE_PW=0; [ -n "$(tfvars_get admin_password)" ] && HAVE_PW=1

# ---- 1. access mode --------------------------------------------------------
say "1/5  Access mode"
echo "  1) tailscale — no public IPs; reach the lab over your tailnet (recommended)"
echo "  2) public    — public IPs, firewall locked to your single IP (/32)"
def=1; [ "$CUR_MODE" = public ] && def=2
while :; do
  case "$(ask "Choose" "$def")" in
    1|tailscale) MODE=tailscale; break ;;
    2|public)    MODE=public; break ;;
    *) warn "Enter 1 or 2." ;;
  esac
done

# ---- 2. region + resource group --------------------------------------------
say "2/5  Azure region and resource group"
LOCATIONS=""
if az account show >/dev/null 2>&1; then
  LOCATIONS="$(az account list-locations --query "[?metadata.regionType=='Physical'].name" -o tsv 2>/dev/null || true)"
fi
while :; do
  LOC="$(ask "Region" "${CUR_LOC:-eastus}")"
  [[ $LOC =~ ^[a-z0-9]+$ ]] || { warn "Region names are lowercase letters/digits, e.g. eastus, canadacentral."; continue; }
  if [ -n "$LOCATIONS" ] && ! printf '%s\n' "$LOCATIONS" | command grep -qx "$LOC"; then
    warn "'$LOC' isn't a region on your subscription. List: az account list-locations -o table"; continue
  fi
  break
done
while :; do
  RG="$(ask "Resource group (created by Terraform)" "${CUR_RG:-rg-adlab-marvel}")"
  [[ $RG =~ ^[-A-Za-z0-9._()]{1,90}$ && $RG != *. ]] && break
  warn "1-90 chars: letters, digits, - _ . ( ) and not ending in '.'"
done

# ---- 3. public IP ----------------------------------------------------------
say "3/5  Your public IP (the firewall's only allowed source in public mode)"
DETECTED="$(detect_ip || true)"
if [ -n "$DETECTED" ]; then echo "  Detected: $DETECTED"; else warn "Couldn't auto-detect your public IP."; fi
DEF_IP="${DETECTED:-${CUR_IP%/32}}"
while :; do
  hint=""; [ "$MODE" = tailscale ] && hint=" (tailscale mode: only kept for the fallback; '-' to skip)"
  IN="$(ask "Public IPv4$hint" "$DEF_IP")"
  if [ "$IN" = "-" ] && [ "$MODE" = tailscale ]; then IP=""; break; fi
  case "$IN" in
    */0|0.0.0.0*) warn "0.0.0.0/0 (or any /0) would open the lab to the whole internet — refused."; continue ;;
    */32) IN="${IN%/32}" ;;
    */*)  warn "Only a single address (/32) is allowed — no ranges."; continue ;;
  esac
  if is_public_ipv4 "$IN"; then IP="${IN}/32"; break; fi
  warn "'$IN' is not a single public IPv4 address (private, reserved and documentation ranges are rejected)."
done

# ---- 4. VM admin password --------------------------------------------------
say "4/5  Azure VM admin password (management/WinRM — not a lab password)"
PW=""
if [ "$HAVE_PW" -eq 1 ] && yes_no "Keep the existing VM admin password?" Y; then
  PW=""   # unchanged
else
  while :; do
    read -rsp "  New password (12+ chars, 3 of: lower/upper/digit/symbol): " PW; echo
    password_ok "$PW" || { warn "Doesn't meet Azure complexity rules."; continue; }
    read -rsp "  Confirm: " PW2; echo
    [ "$PW" = "$PW2" ] && break
    warn "Passwords didn't match."
  done
  unset PW2
fi

# ---- 5. Tailscale auth key -------------------------------------------------
say "5/5  Tailscale auth key"
WRITE_KEY=""
if [ "$MODE" = tailscale ]; then
  if [ -s "$TS_KEY_FILE" ] && yes_no "A key is stored. Keep it?" Y; then
    :
  else
    echo "  Create one: https://login.tailscale.com/admin/settings/keys"
    echo "  reusable: yes | ephemeral: NO | pre-approved: yes | tags: tag:adlab"
    echo "  (Not needed if this lab's DC is already in your tailnet — press Enter to skip.)"
    while :; do
      read -rsp "  Auth key (hidden): " KEY; echo
      [ -z "$KEY" ] && break
      [[ $KEY =~ ^tskey-[A-Za-z0-9-]{20,}$ ]] && { WRITE_KEY=1; break; }
      warn "That doesn't look like a Tailscale auth key (tskey-...)."
    done
  fi
else
  echo "  Not used in public mode."
  if [ -s "$TS_KEY_FILE" ] && yes_no "Delete the stored Tailscale key?" N; then
    rm -f "$TS_KEY_FILE"; echo "  Deleted."
  fi
fi

# ---- write (gitignored files only) -----------------------------------------
NEW_FILE=0; [ -f "$TFVARS" ] || NEW_FILE=1
if [ "$NEW_FILE" -eq 1 ]; then
  ( umask 077; printf '%s\n' \
      '# Written by `make setup` — gitignored, mode 0600. Re-run `make setup` to change.' \
      '# Add your own overrides (vm_size, workstation_os, ...) below; setup keeps them.' > "$TFVARS" )
fi

# Hand values to the writer via env -> JSON on stdin (never argv, never echoed).
SET_MODE="$MODE" SET_LOC="$LOC" SET_RG="$RG" SET_IP="$IP" SET_PW="$PW" python3 -I -c '
import json, os
d = {"access_mode": os.environ["SET_MODE"], "location": os.environ["SET_LOC"],
     "resource_group_name": os.environ["SET_RG"],
     "allowed_source_ip": os.environ["SET_IP"] or None}
if os.environ["SET_PW"]:
    d["admin_password"] = os.environ["SET_PW"]
print(json.dumps(d))' | python3 -I "$REPO_ROOT/scripts/hclvars.py" set "$TFVARS"
unset PW

if [ -n "$WRITE_KEY" ]; then
  ( umask 077; mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
    tmp="$(mktemp "$SECRETS_DIR/.key.XXXXXX")"
    printf '%s\n' "$KEY" > "$tmp"; mv -f "$tmp" "$TS_KEY_FILE" )
fi
unset KEY

[ -n "$(tfvars_get admin_password)" ] || die "No VM admin password set — re-run make setup."

say "Saved"
KEY_STATE="<none>"
if [ -s "$TS_KEY_FILE" ]; then KEY_STATE="stored in .secrets/ (mode 600)"; fi
printf '  %-20s %s\n' "access_mode" "$MODE" "location" "$LOC" "resource_group" "$RG" \
  "allowed_source_ip" "${IP:-<not set>}" "admin_password" "******** (stored)" \
  "tailscale key" "$KEY_STATE"
echo
echo "Next: ./deploy-azure.sh   (re-run make setup any time to change these)"
