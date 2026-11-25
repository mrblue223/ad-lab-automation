# Troubleshooting

## Image SKU not available

**Symptom:** the pre-flight reports `Workstation image ... is not available`, or Terraform returns
`PlatformImageNotFound` / `SkuNotAvailable`.

Windows client SKUs are retired as they go out of servicing. In Nov 2026, for example,
`win11-23h2-pro` is gone from eastus, and 24H2 Pro left servicing in Oct 2026. The image is a
variable, so you can choose any SKU your region offers:

```bash
az vm image list-skus -l eastus -p MicrosoftWindowsDesktop -f windows-11 -o table
az vm image list-skus -l eastus -p MicrosoftWindowsDesktop -f Windows-10 -o table
az vm image show     -l eastus --urn MicrosoftWindowsDesktop:windows-11:win11-25h2-pro:latest
```

```hcl
# terraform.tfvars
ws_client_image = {
  publisher = "MicrosoftWindowsDesktop"
  offer     = "windows-11"
  sku       = "win11-26h2-pro"
  version   = "latest"
}
```

Pick a Gen2 (`V2`), **x64** SKU. Avoid `-arm64` and `pron` variants. If you use NVMe sizes, the
image's `DiskControllerTypes` feature must include NVMe.

**Fallback:** if no client SKU deploys on your subscription, set `workstation_os = "server"`.
The workstations then run Windows Server 2022 instead, which every public region offers.
`deploy-azure.sh` offers to make this change for you, and keeps a backup of tfvars. The DC-focused
PNPT attacks (Kerberoast, DCSync, BloodHound, PtH, AD CS) behave the same either way.

## VM size not offered / quota exceeded

**Symptom:** the pre-flight reports `not offered`, `restricted`, or `Not enough vCPU quota`, or
Terraform returns `QuotaExceeded` / `SkuNotAvailable`.

- Many subscriptions are **no longer offered B-series** sizes (`Standard_B2s` and similar), and
  Free Trial / Student subscriptions get **4 regional vCPUs**. The defaults (DC 2 vCPU plus
  2 × 1 vCPU) fit that limit exactly.
- `az vm list-usage -l eastus -o table` shows the `Total Regional vCPUs` limit and each
  family's limit.
- With more quota, set `ws_vm_size = "Standard_D2als_v7"` so the workstations are less sluggish.
- v6/v7 sizes are **NVMe-only** (`disk_controller_type = "NVMe"`). Older sizes such as Dsv4 need
  `"SCSI"`. The pre-flight tells you which one to use.

## WinRM never comes up

`deploy-azure.sh` waits up to `WINRM_TIMEOUT` (20 min) for TCP 5986, then runs `win_ping` up to
5 times. On failure it prints the status of the `enable-winrm` extension for each VM.

1. **No path to the VM.** In tailscale mode, run `make azure-tailnet`: the DC must be online,
   and the route approved and installed. See [tailscale.md → Troubleshooting](tailscale.md#7-troubleshooting).
   In public mode, check your IP hasn't changed (`make azure-myip`).
2. **The extension failed.** Look at its status (printed by the script), then at the log on the VM:
   ```bash
   az vm run-command invoke -g rg-adlab-marvel -n HYDRA-DC --command-id RunPowerShellScript \
     --scripts "winrm enumerate winrm/config/listener; Get-Content C:\WindowsAzure\lab-bootstrap.log -Tail 30"
   ```
3. **Re-run the bootstrap.** For the DC in tailscale mode this needs a valid key:
   `TF_VAR_tailscale_auth_key=tskey-... terraform -chdir=terraform apply -replace='azurerm_virtual_machine_extension.winrm["HYDRA-DC"]'`
4. **`win_ping` fails with an auth or 401 error** while the port is open: check that
   `ansible_password` in `ansible/inventory/azure_generated.yml` matches `admin_password`.
   The file is regenerated on every apply.
5. **`No module named winrm`:** install pywinrm for Ansible's Python (see the setup guide).

Background: the bootstrap is [`terraform/scripts/bootstrap.ps1.tftpl`](../terraform/scripts/bootstrap.ps1.tftpl),
rendered for each VM and passed inline (base64) through `protected_settings`. Only the DC
downloads anything: the Tailscale MSI, from pkgs.tailscale.com. It
replaced the deprecated `ConfigureRemotingForAnsible.ps1`, which was pulled from GitHub's
`devel` branch and failed on client OSes whose network profile is "Public".

## Bootstrap failed: "network connection types … set to Public"

Fresh Azure VMs, Windows 11 in particular, start with the NIC in the **Public** network
category, and WinRM refuses to create its firewall exception while any profile is Public. The
bootstrap now waits for the network to finish "Identifying", moves every non-domain profile to
**Private**, and only then enables WinRM. It also falls back to `Set-WSManQuickConfig
-SkipNetworkProfileCheck` if needed. Its own 5986 and tailnet firewall rules apply to *every*
profile, so later changes (domain join, the Tailscale adapter) can't close them.

## Re-running after a failed bootstrap

A failed CustomScript run leaves the `enable-winrm` extension in Azure in the **Failed** state
but *not* in Terraform state. azurerm then refuses to create it ("already exists – needs to be
imported"), and extensions can't be installed on deallocated VMs at all. `./deploy-azure.sh`
repairs both before applying:

1. It starts any stopped or deallocated lab VMs.
2. For each VM it compares Terraform state with Azure. It deletes orphaned or Failed extensions
   (or forces `-replace`), so only the bootstraps re-run. **VMs are never rebuilt.**
3. If HYDRA-DC's bootstrap is re-running, it requires the Tailscale key stored by `make setup`.

The bootstrap log on each VM is `C:\WindowsAzure\lab-bootstrap.log`. The extension status shows a
single `LAB-BOOTSTRAP ERROR: …` line that names the fix.

## Domain join fails / bad credentials

**The old bug:** the inventory hardcoded `dc_admin_password=P@$$w0rd` and the join used
`MARVEL\Administrator`. On Azure there is **no usable `Administrator`**. The image's RID-500
account *is* your `admin_username` (`azureadmin`), so after promotion the domain's built-in
admin is `MARVEL\azureadmin` with your tfvars password, and `MARVEL\Administrator` with
`P@$$w0rd` doesn't exist.

**The fix:** joins (and the AD CS setup) use `lab_admin_user` / `lab_admin_password` from
`ansible/group_vars/all.yml`. That resolves to **`MARVEL\tstark`**, a domain user this playbook
creates with a known password and adds to Domain/Enterprise/Schema Admins before any join runs.
It is defined once and is identical on Azure and Vagrant.
On Vagrant, the local RID-500 `Administrator` also gets `builtin_admin_password` (`P@$$w0rd!`)
before promotion, because `Install-ADDSForest` refuses to run with a blank RID-500 password.

If a join still fails:
- `The specified domain either does not exist`: DNS. The role waits for
  `_ldap._tcp.dc._msdcs.MARVEL.local`. Check the DC finished its play.
- `The user name or password is incorrect`: run
  `nxc smb <dc-ip> -u tstark -p 'P@$$w0rd' -d MARVEL.local` to check the DC side.

## DC promotion is slow / looks hung

This is normal. `microsoft.ad.domain` reboots the VM and waits, and Active Directory Web Services
can take a few minutes to start afterwards. The role retries `Get-ADDomain` for up to 10 minutes.

## Clock skew (`KRB_AP_ERR_SKEW`)

Kerberos rejects tickets when the clocks differ by more than 5 minutes. Azure VMs keep accurate
time from the host, so the usual culprit is **your Kali** (especially after a VM snapshot or
suspend):

```bash
sudo timedatectl set-ntp true && timedatectl       # keep Kali synced to internet NTP
# one-off, if systemd-timesyncd isn't running:
sudo apt install ntpsec-ntpdate && sudo ntpdate pool.ntp.org
```

The NSG does not open UDP 123, so you can't sync to the DC directly. You don't need to.

## SMB (445) unreachable from home but 5986 works (public mode)

This doesn't happen in tailscale mode, because SMB travels inside the tunnel. In public mode,
many ISPs block outbound TCP 445. Confirm with `nc -vz <dc-ip> 445`. If it's blocked, switch back to tailscale mode. LDAP, Kerberos and RPC are
unaffected.

## Re-running gives errors instead of converging

It shouldn't. Every task checks the current state first. If one doesn't, please treat it as a
bug. Run with `-vvv` and look at the task that reports `changed` on a second run:

```bash
cd ansible && ansible-playbook -i inventory/azure_generated.yml site.yml
```
