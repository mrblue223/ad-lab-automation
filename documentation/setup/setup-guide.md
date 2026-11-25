# Setup guide (Azure path, from Kali)

## 1. Prerequisites

| Tool | Version | Install on Kali |
|---|---|---|
| Azure CLI (`az`) | 2.60+ | `sudo apt install azure-cli` |
| Terraform | 1.5+ (tested with 1.17) | `sudo apt install terraform` (or the HashiCorp apt repo) |
| Ansible | ansible-core 2.16+ (tested with 2.22) | `sudo apt install ansible-core`, or `pipx install ansible-core` |
| **pywinrm** | for Ansible's Python | `sudo apt install python3-winrm`. For a pipx install: `pipx inject ansible-core pywinrm` |
| Ansible collections | ansible.windows ≥ 2.5, microsoft.ad ≥ 1.7 | `make deps` (`deploy-azure.sh` also installs them) |
| **Tailscale** | for the default access mode | `curl -fsSL https://tailscale.com/install.sh \| sh`, then `sudo tailscale up --accept-routes --operator=$USER`. Full one-time setup (policy, auth key): [tailscale.md](../tailscale.md) |
| python3, curl | | preinstalled |
| Optional | netexec, impacket, shellcheck, ansible-lint | `sudo apt install netexec python3-impacket shellcheck` |

pywinrm must be importable by **the same Python that Ansible runs on**. To see which one that is:

```bash
ansible --version | grep 'python version'     # e.g. (/usr/bin/python3)
/usr/bin/python3 -c 'import winrm' && echo ok
```

## 2. Log in to Azure

```bash
az login                                   # browser / device-code flow
az account show -o table                   # confirm the right subscription
az account set --subscription "<name-or-id>"   # if you have several
```

## 3. `make setup`: your values, entered at runtime

> **This repository contains no secrets and no personal data.** Everything specific to you is
> typed into `make setup` and written **only to gitignored files**. `make audit` proves it
> before you push.

```bash
make setup          # interactive and re-runnable; offers to keep each current value
```

| Step | Asks for | Validation | Stored in (all gitignored) |
|---|---|---|---|
| 1 | Access mode: `tailscale` (default) or `public` | | `terraform/terraform.tfvars` |
| 2 | Azure region, resource group | Region checked against your subscription; RG naming rules | `terraform/terraform.tfvars` |
| 3 | Your public IPv4: auto-detected from 3 services, confirm or type another | Single public address only. Ranges, `/0`, `0.0.0.0`, private and documentation IPs are refused. Stored as `/32`. Optional (`-`) in tailscale mode. | `terraform/terraform.tfvars` |
| 4 | Azure VM admin password (hidden, typed twice) | 12–123 chars, 3 of 4 classes | `terraform/terraform.tfvars` (mode 0600) |
| 5 | Tailscale auth key (hidden), tailscale mode only | `tskey-...` | `.secrets/tailscale-authkey` (mode 0600, never tfvars) |

Before writing, setup **refuses to continue** if either target file isn't gitignored or is
tracked. Values reach the writer on stdin, never on a command line. Your own extra tfvars keys
and comments are preserved. `./deploy-azure.sh` refuses to run until setup has been completed.

You can also add optional overrides to `terraform/terraform.tfvars` by hand. The reference with
**placeholders only** is [`terraform/settings.example.hcl`](../../terraform/settings.example.hcl).

| Variable | Required | Default | Notes |
|---|---|---|---|
| `access_mode` | | `tailscale` | `tailscale` = no public IPs, reached via your tailnet. `public` = fallback, NSG-locked public IPs. |
| `allowed_source_ip` | public mode | `null` | Your IP as `x.x.x.x/32`. Set and maintain it with `make azure-myip`. Validation rejects anything that isn't a /32. |
| `admin_password` | ✓ | | VM admin / WinRM password: 12–123 characters, 3 of the 4 character classes |
| `tailscale_hostname` / `tailscale_tags` | | `marvel-hydra-dc` / `["tag:adlab"]` | Tags must match your auth key and policy |
| `enable_nat_gateway` | | `false` | `true` = NAT gateway for outbound (~$33/month, always billed) instead of free default outbound |
| *(auth key)* | first build | | **Not a tfvars entry.** `make setup` stores it in `.secrets/tailscale-authkey`. |
| `location` | | `eastus` | |
| `vm_size` | | `Standard_D2als_v7` | DC: 2 vCPU / 4 GB |
| `ws_vm_size` | | `Standard_F1as_v7` | Workstations: 1 vCPU / 4 GB. 2 + 1 + 1 = **4 vCPUs**, which fits Free Trial / Student quotas |
| `disk_controller_type` | | `NVMe` | v6/v7 sizes are NVMe-only. Use `SCSI` for older sizes. |
| `workstation_os` | | `client` | `server` = Windows Server workstations, a fallback for when no client SKU deploys |
| `ws_client_image` | | Win11 Pro 25H2 | See [troubleshooting → image SKU](../troubleshooting.md#image-sku-not-available) |
| `ws_license_type` | | `null` | `Windows_Client` if you have Visual Studio/MSDN hosting rights |
| `enable_trusted_launch` | | `true` | Secure Boot + vTPM |

`terraform.tfvars` is gitignored. **Never commit it**, because it holds the VM admin password.

## 4. Check your subscription can host the lab (optional)

`deploy-azure.sh` runs these checks for you. To run them yourself:

```bash
python3 scripts/azure-preflight.py --location eastus \
  --dc-size Standard_D2als_v7 --ws-size Standard_F1as_v7 --ws-count 2 --disk-controller NVMe
terraform -chdir=terraform init && terraform -chdir=terraform plan
```

Next: [runbook.md](../runbook.md).
