#!/usr/bin/env bash
# One-button teardown — removes ALL Azure resources for the lab.
set -euo pipefail
cd "$(dirname "$0")"
echo "==> Destroying the Azure lab (this deletes the VMs, disks, network — everything)"
terraform -chdir=terraform destroy -auto-approve
rm -f ansible/inventory/azure_generated.ini ATTACK_FROM_KALI.txt
echo "==> Gone. You're no longer paying for anything."
