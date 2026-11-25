#!/usr/bin/env bash
# One-button teardown — removes ALL Azure resources for the lab.
#   ./destroy-azure.sh        # asks for confirmation
#   ./destroy-azure.sh -y     # no prompt
set -Eeuo pipefail
cd "$(dirname "$0")"

TFVARS=terraform/terraform.tfvars
TF_EXTRA=()

if ! terraform -chdir=terraform state list >/dev/null 2>&1 \
   || [ -z "$(terraform -chdir=terraform state list 2>/dev/null)" ]; then
  echo "==> No Terraform state found — nothing to destroy here."
  echo "    (If resources exist anyway: az group delete -n rg-adlab-marvel)"
  exit 0
fi

# Destroy doesn't care about these values, but the variables are required.
if [ ! -f "$TFVARS" ]; then
  TF_EXTRA+=(-var "admin_password=Destroy-Placeholder-1!")
fi

RG="$(terraform -chdir=terraform output -raw resource_group_name 2>/dev/null || echo rg-adlab-marvel)"
TS_HOST="$(terraform -chdir=terraform output -raw tailscale_hostname 2>/dev/null || true)"

if [ "${1:-}" != "-y" ]; then
  read -rp "Destroy EVERYTHING in resource group '$RG' (VMs, disks, network)? Type the RG name to confirm: " ans
  [ "$ans" = "$RG" ] || { echo "Aborted."; exit 1; }
fi

echo "==> Destroying the Azure lab"
terraform -chdir=terraform destroy -input=false -auto-approve "${TF_EXTRA[@]}"
rm -f ansible/inventory/azure_generated.yml ansible/inventory/azure_generated.ini ATTACK_FROM_KALI.txt
echo "==> Gone. You're no longer paying for anything."
if [ -n "$TS_HOST" ]; then
  echo "==> Remove '$TS_HOST' from your tailnet so the next build reuses the name:"
  echo "    https://login.tailscale.com/admin/machines  (… -> Remove)"
fi
