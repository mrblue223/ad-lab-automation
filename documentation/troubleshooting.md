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

Each VM is bootstrapped by an Azure **managed Run Command** named `lab-bootstrap`. Azure writes
[`terraform/scripts/bootstrap.ps1.tftpl`](../terraform/scripts/bootstrap.ps1.tftpl), rendered for
that VM, to a plain `.ps1` file and runs it. Terraform reads the **real exit code**: if the
script fails, `terraform apply` fails with the script's error. A broken bootstrap can no longer
show up as a "succeeded" extension.

`deploy-azure.sh` then waits up to `WINRM_TIMEOUT` (20 min) for TCP 5986 and runs `win_ping` up
to 5 times. On failure it prints each VM's bootstrap state, exit code and output.

1. **No path to the VM.** In tailscale mode, run `make azure-tailnet`: the DC must be online,
   and the route approved and installed. See [tailscale.md → Troubleshooting](tailscale.md#7-troubleshooting).
   In public mode, check your IP hasn't changed (`make azure-myip`).
2. **The bootstrap failed.** Check its status and the log on the VM:
   ```bash
   az vm run-command show -g rg-adlab-marvel --vm-name THEPUNISHER --name lab-bootstrap --instance-view \
     --query "instanceView.{state:executionState,exit:exitCode,error:error}"
   az vm run-command invoke -g rg-adlab-marvel -n THEPUNISHER --command-id RunPowerShellScript \
     --scripts "Get-Content C:\WindowsAzure\lab-bootstrap.log -Tail 30"
   ```
3. **Re-run it:** run `./deploy-azure.sh` again. It replaces any bootstrap whose last run exited
   non-zero, and supplies the DC's Tailscale key from `make setup`. Only that step re-runs.
4. **`win_ping` fails with an auth or 401 error** while the port is open: check that
   `ansible_password` in `ansible/inventory/azure_generated.yml` matches `admin_password`.
   The file is regenerated on every apply.
5. **`No module named winrm`:** install pywinrm for Ansible's Python (see the setup guide).

Only the DC downloads anything during bootstrap: the Tailscale MSI, from pkgs.tailscale.com.
The bootstrap replaced the deprecated `ConfigureRemotingForAnsible.ps1`.

## Bootstrap "succeeded" but did nothing: Microsoft Defender

**What happened on the first real deploy.** The bootstrap used to be passed to a CustomScript
extension as one command line: base64 → `GzipStream` → `[ScriptBlock]::Create`, which kept it
under cmd.exe's length limit. That is precisely the shape of a malware PowerShell stager.
Defender's behaviour monitor (Tamper Protection on, as on every fresh Azure image) killed the
process before the script's first line, as `Behavior:Win32/PShellCobStager.A`. The extension
still reported success.

How it was confirmed, if you ever need to check again:

```bash
az vm run-command invoke -g rg-adlab-marvel -n <VM> --command-id RunPowerShellScript \
  --scripts "Get-MpThreatDetection | Select InitialDetectionTime,ThreatID,ProcessName"
```

**The fix:** the bootstrap is now an ordinary script file (managed Run Command), with no encoded
or compressed loader, and the Tailscale key arrives as an encrypted *protected parameter*
instead of being embedded in the script. Don't reintroduce an encoded wrapper to save space:
Run Command has no 8191-character limit.

Note: Defender also explains why the lab's "disable Defender" weakening is best-effort on Azure
images. Tamper Protection can veto `Set-MpPreference`, and the DC's GPO is the backstop.

## Bootstrap failed: "network connection types … set to Public"

Fresh Azure VMs, Windows 11 in particular, start with the NIC in the **Public** network
category, and WinRM refuses to create its firewall exception while any profile is Public. The
bootstrap waits for the network to finish "Identifying", moves every non-domain profile to
**Private**, and only then enables WinRM. It falls back to `Set-WSManQuickConfig
-SkipNetworkProfileCheck` if needed. Its own 5986 and tailnet firewall rules apply to *every*
profile, so later changes (domain join, the Tailscale adapter) can't close them.

## Re-running after a failed bootstrap

`./deploy-azure.sh` repairs a previous failed run before applying:

1. It starts any stopped or deallocated lab VMs, because Run Commands need a running VM.
2. For each VM it compares Terraform state with Azure:
   - a `lab-bootstrap` that Azure has but state doesn't (an interrupted apply) is deleted, so
     azurerm can create it;
   - one whose last run exited non-zero is `-replace`d;
   - leftover CustomScript `enable-winrm` extensions from older versions are removed.
3. If HYDRA-DC's bootstrap is re-running, it requires the Tailscale key stored by `make setup`.

**VMs are never rebuilt.** The bootstrap log on each VM is `C:\WindowsAzure\lab-bootstrap.log`,
and a failure ends with a single `LAB-BOOTSTRAP ERROR: …` line that names the fix.

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
