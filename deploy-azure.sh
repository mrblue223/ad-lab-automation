#!/usr/bin/env bash
# =============================================================================
#  deploy-azure.sh — ONE BUTTON.
#  Builds the entire MARVEL.local lab in Azure and configures the domain.
#
#  Run from your Kali (or any Linux with az, terraform, ansible):
#     ./deploy-azure.sh
#
#  It will:
#    1. check you're logged into Azure
#    2. detect your public IP and lock the lab's firewall to it
#    3. terraform apply  -> VNet + DC + 2 workstations + WinRM
#    4. auto-generate the Ansible inventory (no copy/paste)
#    5. wait for WinRM, then ansible -> promote DC, users, SPN, GPO, domain-join
#    6. print the attack cheat-sheet (ATTACK_FROM_KALI.txt)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

say() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR: %s\033[0m\n" "$*" >&2; exit 1; }

# ---- 0. prerequisites ----
for bin in az terraform ansible-playbook curl; do
  command -v "$bin" >/dev/null || die "$bin not found. Install it first (see docs/deploy.md)."
done

say "Checking Azure login"
az account show >/dev/null 2>&1 || die "Not logged into Azure. Run: az login"
az account show --query '{subscription:name, user:user.name}' -o yaml

# ---- 1. ensure collections ----
say "Installing Ansible collections (idempotent)"
ansible-galaxy collection install -r ansible/requirements.yml >/dev/null

# ---- 2. tfvars: detect your public IP, prompt for a VM password if needed ----
TFVARS=terraform/terraform.tfvars
if [ ! -f "$TFVARS" ]; then
  say "First run — creating $TFVARS"
  MYIP="$(curl -s https://ifconfig.me)"
  [ -n "$MYIP" ] || die "Couldn't detect your public IP; set allowed_source_ip manually."
  read -rsp "Choose a VM admin password (12+ chars, 3 of 4 classes): " VMPASS; echo
  cat > "$TFVARS" <<EOF
allowed_source_ip = "${MYIP}/32"
admin_password    = "${VMPASS}"
EOF
  echo "Wrote $TFVARS (allowed_source_ip=${MYIP}/32)"
else
  # refresh your IP each run in case it changed
  MYIP="$(curl -s https://ifconfig.me)"
  if [ -n "$MYIP" ] && ! grep -q "$MYIP" "$TFVARS"; then
    say "Your public IP changed to $MYIP — updating $TFVARS"
    sed -i "s#allowed_source_ip *=.*#allowed_source_ip = \"${MYIP}/32\"#" "$TFVARS"
  fi
fi

# ---- 3. terraform ----
say "Terraform: provisioning Azure infrastructure"
terraform -chdir=terraform init -input=false
terraform -chdir=terraform apply -auto-approve

# ---- 4. wait for WinRM on the DC ----
DC_IP="$(terraform -chdir=terraform output -raw dc_public_ip)"
say "Waiting for WinRM on the DC ($DC_IP:5986) — the CustomScript extension can take a couple of minutes"
for i in $(seq 1 30); do
  if timeout 5 bash -c "</dev/tcp/${DC_IP}/5986" 2>/dev/null; then
    echo "WinRM is up."; break
  fi
  printf '.'; sleep 10
  [ "$i" -eq 30 ] && die "WinRM never came up. Check the VM's boot diagnostics in the portal."
done

# ---- 5. ansible: build the domain ----
say "Ansible: building MARVEL.local (DC promotion, users, SPN, GPO, domain-join)"
ansible-playbook -i ansible/inventory/azure_generated.ini ansible/site.yml

# ---- 6. done ----
say "DONE. Your lab is live. Attack details:"
cat ATTACK_FROM_KALI.txt

cat <<EOF

\033[1;32mStart playing:\033[0m
  # add the DC to /etc/hosts (see above), then:
  nxc smb ${DC_IP} -u fcastle -p Password1 -d MARVEL.local

\033[1;33mWhen you're done for the day (STOP PAYING):\033[0m
  az vm deallocate --ids \$(az vm list -g rg-adlab-marvel --query "[].id" -o tsv)
\033[1;33mStart it again later:\033[0m
  az vm start --ids \$(az vm list -g rg-adlab-marvel --query "[].id" -o tsv)
\033[1;31mNuke everything:\033[0m
  ./destroy-azure.sh
EOF
