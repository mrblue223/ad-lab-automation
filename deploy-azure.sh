#!/usr/bin/env bash
# =============================================================================
#  deploy-azure.sh — ONE BUTTON.
#  Builds the entire MARVEL.local lab in Azure and configures the domain.
#
#     make setup          # once (and whenever you want to change a value)
#     ./deploy-azure.sh
#
#  All user-specific values (IP, VM password, Tailscale key, region) come from
#  `make setup`, which writes them only to gitignored files. This script never
#  prompts for or writes them; it refuses to run until setup has been done.
#
#  Steps:
#    0. pre-flight: setup done?, tools, pywinrm, az login, Ansible collections
#    1. detect your public IP (only used by access_mode = "public")
#    3. check images, VM sizes and vCPU quota in your region/subscription
#    3c. tailscale mode: check Kali's Tailscale; load the auth key from .secrets/
#    4. terraform apply  -> VNet + NSG + DC + 2 workstations (+ Tailscale on the DC)
#    5. tailscale mode: wait for HYDRA-DC's subnet route; then WinRM on every VM
#    6. ansible -> promote DC, AD CS, users, SPN, GPO, domain-join
#    7. smoke test + print ATTACK_FROM_KALI.txt
#
#  Environment overrides:
#    TS_AUTHKEY=tskey-auth-...  use this key instead of .secrets/tailscale-authkey
#    ALLOWED_IP=203.0.113.45    skip IP auto-detection (public mode)
#    WINRM_TIMEOUT=1200         seconds to wait for the tunnel / WinRM (default 20 min)
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=scripts/lib.sh
source scripts/lib.sh                           # say/warn/die, detect_ip, TFVARS, TS_KEY_FILE

INVENTORY=inventory/azure_generated.yml        # relative to ansible/
WINRM_TIMEOUT="${WINRM_TIMEOUT:-1200}"
TF_EXTRA=()                                     # per-run -var overrides (plan/console/apply)
APPLY_EXTRA=()                                  # apply-only flags (e.g. -replace)

trap 'printf "\n\033[1;31mFAILED (line %s): %s\033[0m\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

tf() { terraform -chdir=terraform "$@"; }

# ---- 0. pre-flight ---------------------------------------------------------
if [ ! -f "$TFVARS" ] || [ -z "$(tfvars_get admin_password)" ]; then
  die "Setup hasn't been completed (no terraform/terraform.tfvars with an admin password).
  Run:  make setup     (interactive; writes only gitignored files)"
fi
assert_gitignored "$TFVARS" "$TS_KEY_FILE"

say "Pre-flight checks"
for bin in az terraform ansible ansible-playbook ansible-galaxy curl python3 timeout; do
  command -v "$bin" >/dev/null || die "'$bin' not found. See documentation/setup/setup-guide.md."
done

ANSIBLE_PY="$(ansible --version | sed -n 's/.*python version = .*(\([^)]*\))$/\1/p')"
"${ANSIBLE_PY:-python3}" -c 'import winrm' 2>/dev/null \
  || die "pywinrm is missing for Ansible's Python (${ANSIBLE_PY:-python3}).
       Kali/Debian:  sudo apt install python3-winrm
       pipx Ansible: pipx inject ansible-core pywinrm   (or: pipx inject ansible pywinrm)"

az account show >/dev/null 2>&1 || die "Not logged into Azure. Run: az login"
az account show --query '{subscription:name, id:id, user:user.name}' -o yaml

say "Installing Ansible collections (idempotent)"
ansible-galaxy collection install -r ansible/requirements.yml >/dev/null

# ---- 1. public IP ----------------------------------------------------------
say "Detecting your public IPv4"
MYIP="${ALLOWED_IP:-}"
if [ -z "$MYIP" ]; then MYIP="$(detect_ip || true)"; fi
if [ -n "$MYIP" ]; then echo "You are $MYIP"; fi
CURRENT_IP="$(tfvars_get allowed_source_ip)"

# ---- 3. terraform init + image pre-flight ----------------------------------
say "Terraform init"
tf init -input=false >/dev/null

say "Checking VM images are available"
IMG_INFO="$(printf '%s\n' 'jsonencode({loc = var.location, os = var.workstation_os, dc = var.dc_image, ws = local.ws_image, dc_size = var.vm_size, ws_size = local.ws_vm_size, n_ws = length(var.workstation_ips), ctrl = var.disk_controller_type, mode = var.access_mode, ts_host = var.tailscale_hostname, subnet = var.address_space, rg = var.resource_group_name, ws_names = join(",", keys(var.workstation_ips))})' \
  | tf console "${TF_EXTRA[@]}")"
read -r LOCATION WS_OS DC_URN WS_URN DC_SIZE WS_SIZE N_WS DISK_CTRL ACCESS_MODE TS_HOST LAB_SUBNET RG WS_NAMES < <(python3 -c '
import json, sys
d = json.loads(json.loads(sys.argv[1]))
urn = lambda i: ":".join([i["publisher"], i["offer"], i["sku"], i["version"]])
print(d["loc"], d["os"], urn(d["dc"]), urn(d["ws"]), d["dc_size"], d["ws_size"], d["n_ws"], d["ctrl"], d["mode"], d["ts_host"], d["subnet"], d["rg"], d["ws_names"])' "$IMG_INFO")

image_ok() { az vm image show --location "$LOCATION" --urn "$1" -o none 2>/dev/null; }

image_ok "$DC_URN" || die "DC image $DC_URN is not available in $LOCATION.
  List options:  az vm image list-skus -l $LOCATION -p MicrosoftWindowsServer -f WindowsServer -o table
  Then set dc_image in $TFVARS."
echo "  DC          : $DC_URN  ✓"

if image_ok "$WS_URN"; then
  echo "  Workstations: $WS_URN  ✓ ($WS_OS)"
else
  publisher="${WS_URN%%:*}"; rest="${WS_URN#*:}"; offer="${rest%%:*}"
  warn "Workstation image $WS_URN is not available in $LOCATION for this subscription."
  cat >&2 <<EOF
  Options:
    a) choose another client SKU:
         az vm image list-skus -l $LOCATION -p $publisher -f $offer -o table
         az vm image list-skus -l $LOCATION -p MicrosoftWindowsDesktop -f Windows-10 -o table
       and set ws_client_image in $TFVARS (see terraform.tfvars.example)
    b) fall back to Windows Server for the workstations (DC-focused attacks are unaffected)
EOF
  [ "$WS_OS" = "client" ] || die "Server fallback image is unavailable too — pick a SKU manually."
  read -rp "Fall back to Windows Server workstations? This appends workstation_os = \"server\" to $TFVARS (backup kept) [y/N] " ans
  [[ $ans =~ ^[Yy]$ ]] || die "Aborted. Pick a client SKU and re-run."
  cp -p "$TFVARS" "$TFVARS.bak"
  printf '\n# Added by deploy-azure.sh: client image unavailable in %s\nworkstation_os = "server"\n' "$LOCATION" >> "$TFVARS"
  echo "Updated $TFVARS (backup: $TFVARS.bak)."
fi

# ---- 3b. VM size / disk controller / vCPU quota pre-flight -----------------
say "Checking VM sizes and vCPU quota in $LOCATION"
PREFLIGHT_ARGS=(--location "$LOCATION" --dc-size "$DC_SIZE" --ws-size "$WS_SIZE"
                --ws-count "$N_WS" --disk-controller "$DISK_CTRL")
# Quota only matters before the VMs exist (afterwards they already hold it).
if tf state list 2>/dev/null | command grep -q '^azurerm_windows_virtual_machine\.'; then
  PREFLIGHT_ARGS+=(--skip-quota)
fi
python3 scripts/azure-preflight.py "${PREFLIGHT_ARGS[@]}" || die "Pre-flight failed (see above). Adjust $TFVARS and re-run."

# ---- 3a. repair a previous failed run (existing VMs only) --------------------
# Bootstraps run as managed Run Command "lab-bootstrap" (a plain .ps1 file).
# Before applying: start deallocated VMs (commands need a running VM), remove
# leftovers Azure has but Terraform doesn't (azurerm won't create over them),
# and force a re-run of any bootstrap whose last run exited non-zero.
# Legacy CustomScript "enable-winrm" extensions are cleaned up too.
# The VMs themselves are never rebuilt.
BOOT_ADDR() { printf 'azurerm_virtual_machine_run_command.bootstrap["%s"]' "$1"; }
REBOOTSTRAP=()
if tf state list 2>/dev/null | command grep -q '^azurerm_windows_virtual_machine\.'; then
  say "Existing lab found — checking VM power state and bootstraps"
  IFS=',' read -r -a WS_LIST <<< "$WS_NAMES"
  ALL_VMS=("HYDRA-DC" "${WS_LIST[@]}")

  mapfile -t STOPPED < <(az vm list -g "$RG" -d --query "[?powerState!='VM running'].name" -o tsv 2>/dev/null)
  if [ "${#STOPPED[@]}" -gt 0 ]; then
    echo "  Starting stopped/deallocated VMs: ${STOPPED[*]}"
    for vm in "${STOPPED[@]}"; do az vm start -g "$RG" -n "$vm" --no-wait; done
    for vm in "${STOPPED[@]}"; do
      az vm wait -g "$RG" -n "$vm" --custom "instanceView.statuses[?code=='PowerState/running']" --timeout 900 \
        || die "$vm did not start. Check: az vm get-instance-view -g $RG -n $vm"
    done
  fi

  STATE_JSON="$(tf show -json)"
  state_of() {   # absent | tainted | exit:<code>
    python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
rs = d.get("values", {}).get("root_module", {}).get("resources", [])
r = next((r for r in rs if r["address"] == sys.argv[1]), None)
if r is None: print("absent")
elif r.get("tainted"): print("tainted")
else:
    iv = (r.get("values", {}).get("instance_view") or [{}])[0]
    print("exit:%s" % iv.get("exit_code"))' "$1" <<< "$STATE_JSON"
  }
  for vm in "${ALL_VMS[@]}"; do
    # legacy CustomScript extension: only an orphan (not in state) needs deleting
    legacy="azurerm_virtual_machine_extension.winrm[\"$vm\"]"
    if [ "$(state_of "$legacy")" = absent ] && az vm extension show -g "$RG" --vm-name "$vm" -n enable-winrm -o none 2>/dev/null; then
      echo "  $vm: removing legacy enable-winrm CustomScript extension"
      az vm extension delete -g "$RG" --vm-name "$vm" -n enable-winrm -o none || warn "could not delete enable-winrm on $vm"
    fi

    addr="$(BOOT_ADDR "$vm")"
    st="$(state_of "$addr")"
    in_azure=0
    az vm run-command show -g "$RG" --vm-name "$vm" --name lab-bootstrap -o none 2>/dev/null && in_azure=1
    case "$st" in
      absent)
        if [ "$in_azure" -eq 1 ]; then
          warn "$vm: lab-bootstrap exists in Azure but not in Terraform state (interrupted run) — deleting it."
          az vm run-command delete -g "$RG" --vm-name "$vm" --name lab-bootstrap --yes -o none
        fi
        REBOOTSTRAP+=("$vm") ;;
      tainted) REBOOTSTRAP+=("$vm") ;;                        # Terraform replaces tainted resources itself
      exit:0)  ;;                                             # last run succeeded: leave alone
      *)
        warn "$vm: last bootstrap run ${st/exit:/exited } — forcing a re-run."
        APPLY_EXTRA+=("-replace=$addr"); REBOOTSTRAP+=("$vm") ;;
    esac
    printf '  %-12s bootstrap=%s\n' "$vm" "$st"
  done
  unset STATE_JSON
  if [ "${#REBOOTSTRAP[@]}" -gt 0 ]; then echo "  Bootstrap will (re)run on: ${REBOOTSTRAP[*]}  (VMs are not rebuilt)"; fi
fi

# ---- 3c. access-mode specific pre-flight ------------------------------------
if [ "$ACCESS_MODE" = "public" ]; then
  say "Access mode: public (NSG locked to your /32)"
  if [ -z "$MYIP" ]; then
    [ -n "$CURRENT_IP" ] || die "No allowed_source_ip and couldn't detect your IP. Run: make setup (or make azure-myip)"
    warn "Couldn't detect your public IP — using allowed_source_ip from $TFVARS ($CURRENT_IP)."
  elif [ "$CURRENT_IP" != "${MYIP}/32" ]; then
    warn "$TFVARS allows ${CURRENT_IP:-nothing}, but you are now ${MYIP}."
    warn "Using -var allowed_source_ip=${MYIP}/32 for THIS run; $TFVARS is left untouched."
    warn "To make it permanent: make azure-myip"
    TF_EXTRA+=(-var "allowed_source_ip=${MYIP}/32")
  fi
else
  say "Access mode: tailscale (no public IPs; HYDRA-DC = $TS_HOST routes $LAB_SUBNET)"
  command -v tailscale >/dev/null || die "Tailscale isn't installed on this machine.
  Install:  curl -fsSL https://tailscale.com/install.sh | sh
  Then:     sudo tailscale up --accept-routes
  See documentation/tailscale.md (do the ACL policy step first!)."
  python3 scripts/tailnet-check.py kali || die "Fix Tailscale on this machine, then re-run."

  # The auth key is only needed when HYDRA-DC's bootstrap runs: on the first
  # build, or when switching an existing lab from public -> tailscale (the
  # bootstrap is one-shot, so it is re-run explicitly).
  NEED_KEY=0
  if ! tf state list 2>/dev/null | command grep -qF "$(BOOT_ADDR HYDRA-DC)"; then
    NEED_KEY=1
  elif printf '%s\n' "${REBOOTSTRAP[@]}" | command grep -qx 'HYDRA-DC'; then
    NEED_KEY=1                                  # DC bootstrap is being retried
  elif [ "$(tf output -raw access_mode 2>/dev/null || true)" = "public" ]; then
    warn "Switching this lab from public to tailscale access: re-running HYDRA-DC's bootstrap."
    APPLY_EXTRA+=("-replace=$(BOOT_ADDR HYDRA-DC)")
    NEED_KEY=1
  fi
  if [ "$NEED_KEY" -eq 1 ]; then
    TS_KEY="${TS_AUTHKEY:-}"
    if [ -z "$TS_KEY" ] && [ -s "$TS_KEY_FILE" ]; then TS_KEY="$(head -n1 "$TS_KEY_FILE")"; fi
    [ -n "$TS_KEY" ] || die "HYDRA-DC needs a Tailscale auth key to join your tailnet, and none is stored.
  Run:  make setup     (step 5 stores it in .secrets/, gitignored)"
    [[ $TS_KEY == tskey-* ]] || die "The stored Tailscale key doesn't look like tskey-... — re-run make setup."
    export TF_VAR_tailscale_auth_key="$TS_KEY"   # env only — never written to tfvars
    unset TS_KEY
  fi
fi

# ---- 4. terraform apply ----------------------------------------------------
say "Terraform: provisioning Azure infrastructure (≈10 min)"
tf apply -input=false -auto-approve "${TF_EXTRA[@]}" "${APPLY_EXTRA[@]}"

unset TF_VAR_tailscale_auth_key
RG="$(tf output -raw resource_group_name)"
DC_IP="$(tf output -raw dc_address)"
declare -A HOSTS=()
while read -r name ip; do HOSTS["$name"]="$ip"; done < <(
  tf output -json access_addresses | python3 -c 'import json,sys; [print(k, v) for k, v in json.load(sys.stdin).items()]')

# ---- 5a. tailscale mode: wait for the DC's subnet route --------------------
if [ "$ACCESS_MODE" = "tailscale" ]; then
  say "Waiting for $TS_HOST to join your tailnet and route $LAB_SUBNET"
  deadline=$((SECONDS + WINRM_TIMEOUT)); last=""
  while :; do
    rc=0; msg="$(python3 scripts/tailnet-check.py router --hostname "$TS_HOST" --subnet "$LAB_SUBNET" 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] && { echo "$msg"; break; }
    [ "$rc" -eq 1 ] && die "$msg"
    [ "$msg" != "$last" ] && { echo; echo "$msg"; last="$msg"; }
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "HYDRA-DC bootstrap status:" >&2
      az vm run-command show -g "$RG" --vm-name HYDRA-DC --name lab-bootstrap --instance-view \
        --query "instanceView.{state:executionState,exit:exitCode,error:error}" -o yaml >&2 || true
      die "Tunnel to the lab never came up. Bootstrap log on the VM:
  az vm run-command invoke -g $RG -n HYDRA-DC --command-id RunPowerShellScript --scripts 'Get-Content C:\\WindowsAzure\\lab-bootstrap.log -Tail 40'
See documentation/tailscale.md -> Troubleshooting."
    fi
    printf '.'; sleep 15
  done
fi

# ---- 5. wait for WinRM -----------------------------------------------------
winrm_diagnostics() {
  printf '\n\033[1;31mWinRM did not come up on: %s\033[0m\n' "$*" >&2
  echo "Bootstrap (Run Command lab-bootstrap) status:" >&2
  for h in "$@"; do
    echo "--- $h" >&2
    az vm run-command show -g "$RG" --vm-name "$h" --name lab-bootstrap --instance-view \
      --query "instanceView.{state:executionState,exit:exitCode,error:error,output:output}" -o yaml 2>&1 | tail -25 >&2 || true
  done
  echo "Defender detections that could have killed it (should be none):" >&2
  echo "  az vm run-command invoke -g $RG -n <VM> --command-id RunPowerShellScript --scripts 'Get-MpThreatDetection | Select InitialDetectionTime,ThreatID,ProcessName'" >&2
  cat >&2 <<EOF

Next steps:
  * tailscale mode: is $LAB_SUBNET still routed to you?  python3 scripts/tailnet-check.py router --hostname $TS_HOST --subnet $LAB_SUBNET
  * public mode: is your IP still ${MYIP:-<unknown>}? The NSG only admits allowed_source_ip (make azure-myip).
  * Check the listener directly (no WinRM needed):
      az vm run-command invoke -g $RG -n <VM> --command-id RunPowerShellScript \\
        --scripts "winrm enumerate winrm/config/listener; Get-Content C:\\WindowsAzure\\lab-bootstrap.log -Tail 30"
  * Re-run just one bootstrap:  terraform -chdir=terraform apply -replace='azurerm_virtual_machine_run_command.bootstrap["<VM>"]'
    (HYDRA-DC also needs TF_VAR_tailscale_auth_key — ./deploy-azure.sh supplies it from make setup)
  * Then simply re-run ./deploy-azure.sh (everything is idempotent).
See documentation/troubleshooting.md → "WinRM never comes up".
EOF
  exit 1
}

say "Waiting for WinRM/HTTPS (5986) on all VMs — up to $((WINRM_TIMEOUT / 60)) min"
deadline=$((SECONDS + WINRM_TIMEOUT))
pending=("${!HOSTS[@]}")
while [ "${#pending[@]}" -gt 0 ]; do
  still=()
  for h in "${pending[@]}"; do
    if timeout 5 bash -c "</dev/tcp/${HOSTS[$h]}/5986" 2>/dev/null; then
      printf '\n  %s (%s) port 5986 open' "$h" "${HOSTS[$h]}"
    else
      still+=("$h")
    fi
  done
  pending=("${still[@]+"${still[@]}"}")
  [ "${#pending[@]}" -eq 0 ] && break
  [ "$SECONDS" -ge "$deadline" ] && winrm_diagnostics "${pending[@]}"
  printf '.'; sleep 15
done
echo

say "Authenticating over WinRM (win_ping)"
ok=0
for attempt in 1 2 3 4 5; do
  if (cd ansible && ansible all -i "$INVENTORY" -m ansible.windows.win_ping -o); then ok=1; break; fi
  warn "win_ping attempt $attempt failed; retrying in 30s"; sleep 30
done
[ "$ok" -eq 1 ] || winrm_diagnostics "${!HOSTS[@]}"

# ---- 6. ansible ------------------------------------------------------------
say "Ansible: building MARVEL.local (DC promotion, AD CS, users, SPN, GPO, domain-join) ≈20-30 min"
(cd ansible && ansible-playbook -i "$INVENTORY" site.yml)

# ---- 7. smoke test + summary ----------------------------------------------
if command -v nxc >/dev/null; then
  say "Smoke test: authenticating as fcastle"
  nxc smb "$DC_IP" -u fcastle -p Password1 -d MARVEL.local || warn "nxc check failed — see documentation/troubleshooting.md."
fi

say "DONE. Your lab is live."
cat ATTACK_FROM_KALI.txt

# The $(...) below is printed for the user to copy, not executed here.
# shellcheck disable=SC2016
{
printf '\n\033[1;33mWhen you are done for the day (stop paying for compute):\033[0m\n'
printf '  az vm deallocate --ids $(az vm list -g %s --query "[].id" -o tsv)\n' "$RG"
printf '\033[1;33mStart it again later:\033[0m\n'
printf '  az vm start --ids $(az vm list -g %s --query "[].id" -o tsv)\n' "$RG"
printf '\033[1;31mNuke everything:\033[0m\n  ./destroy-azure.sh\n'
}
