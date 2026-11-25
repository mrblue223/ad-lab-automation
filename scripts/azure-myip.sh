#!/usr/bin/env bash
# =============================================================================
#  azure-myip.sh  (make azure-myip) — set allowed_source_ip to your current IP
#
#  * Updates allowed_source_ip in terraform/terraform.tfvars (gitignored,
#    mode 0600; previous copy kept as terraform.tfvars.bak, also gitignored).
#  * access_mode = "public" and the lab is deployed -> terraform apply so the NSG
#    follows you (you review + confirm the plan).
#  * access_mode = "tailscale" -> nothing is exposed; the IP is only saved so the
#    public fallback is ready.
#
#  ALLOWED_IP=203.0.113.45 make azure-myip   to set it explicitly.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ -f "$TFVARS" ] || die "No terraform.tfvars yet — run: make setup"
assert_gitignored "$TFVARS" "$TFVARS.bak"

MYIP="${ALLOWED_IP:-$(detect_ip || true)}"
MYIP="${MYIP%/32}"
is_public_ipv4 "$MYIP" || die "Couldn't detect a public IPv4 (or '$MYIP' isn't one). Use ALLOWED_IP=x.x.x.x"
NEW="${MYIP}/32"

OLD="$(tfvars_get allowed_source_ip)"
if [ "$OLD" = "$NEW" ]; then
  echo "allowed_source_ip is already $NEW"
else
  cp -p "$TFVARS" "$TFVARS.bak"
  printf '{"allowed_source_ip": "%s"}' "$NEW" | python3 -I "$REPO_ROOT/scripts/hclvars.py" set "$TFVARS"
  echo "allowed_source_ip: ${OLD:-<unset>} -> $NEW   (backup: terraform/terraform.tfvars.bak)"
fi

MODE="$(terraform -chdir="$REPO_ROOT/terraform" output -raw access_mode 2>/dev/null || true)"
case "$MODE" in
  public)
    echo "Lab is in public mode — updating the NSG (review the plan, then confirm):"
    terraform -chdir="$REPO_ROOT/terraform" apply
    ;;
  tailscale)
    echo "Lab is in tailscale mode: no inbound internet rules exist, nothing to update."
    echo "(Saved for the fallback: choose 'public' in make setup, then re-run ./deploy-azure.sh.)"
    ;;
  *)
    echo "Lab isn't deployed — the new value is used on the next ./deploy-azure.sh (public mode only)."
    ;;
esac
