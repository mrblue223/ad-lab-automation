# AD Lab Automation — MARVEL.local (Vagrant + Terraform)

One-command deployment of a deliberately-vulnerable Active Directory lab, **locally** with
Vagrant/VirtualBox **or** in the **cloud** with Terraform/Azure. Both paths share the same
Ansible configuration, so the domain comes out identical either way.

Companion to my [AD pentest write-ups](../ad-pentest-lab) — this repo *builds* the lab those
attacks run against.

> ⚠️ Deliberately insecure by design (weak passwords, no SMB signing, Defender/firewall off,
> creds in a Description field). Deploy only in an isolated environment you own.

---

## What it builds

| Host | Role | OS | IP |
|------|------|----|----|
| HYDRA-DC | Domain Controller + AD CS | Windows Server 2022 | 10.0.2.10 |
| THEPUNISHER | Workstation | Windows 11 (Azure) / 10 (Vagrant) | 10.0.2.11 |
| SPIDERMAN | Workstation | Windows 11 (Azure) / 10 (Vagrant) | 10.0.2.12 |

Fully configured: forest `MARVEL.local`, four users (incl. a Domain Admin and a Kerberoastable
service account), the `hackme` share, an SPN, a Defender-disabling GPO, both workstations
domain-joined with `fcastle` seeded as local admin.

---

## Architecture

```
                    ┌─────────────────────────────┐
                    │   ansible/  (shared config)  │
                    │  roles: domain_controller,   │
                    │         domain_member        │
                    │  group_vars/all.yml  ← truth │
                    └──────────────┬──────────────┘
                                   │ WinRM
              ┌────────────────────┴────────────────────┐
              │                                          │
     ┌────────▼─────────┐                      ┌─────────▼────────┐
     │  vagrant/        │                      │  terraform/      │
     │  VirtualBox VMs  │                      │  Azure VMs       │
     │  (local)         │                      │  (cloud)         │
     └──────────────────┘                      └──────────────────┘
```

The **single source of truth** is [`ansible/group_vars/all.yml`](ansible/group_vars/all.yml) —
domain name, users, IPs, SPN, share, and which weakenings to apply. Change the lab there once and
both deploy paths follow.

---

## Quick start

### Cloud (Azure) — the one button ⭐

From your Kali (needs `az`, `terraform`, `ansible` + `pywinrm`, and **Tailscale**; run `az login`
first. See [the setup guide](documentation/setup/setup-guide.md), and do the one-time
[Tailscale steps](documentation/tailscale.md), including the tailnet policy):
```bash
make setup           # prompts for your values; writes ONLY gitignored files
./deploy-azure.sh
```
> **No secrets in this repo.** Your public IP, VM password, Tailscale key and region are entered
> at runtime and never committed. `make audit` checks the tree and full git history before you push.

The deploy script:
1. pre-flights image SKU, VM sizes, vCPU quota, and your Kali's Tailscale
2. `terraform apply` → VNet + DC + 2 workstations, **no public IPs, no inbound internet rules**
3. HYDRA-DC joins your tailnet as a subnet router for `10.0.2.0/24`, so you reach every host at its course IP
4. **auto-generates** the Ansible inventory (no copy/paste)
5. waits for WinRM, then Ansible builds the whole domain
6. prints `ATTACK_FROM_KALI.txt` (gitignored) with the lab addresses and verification commands

Then work straight from your home Kali, over the tunnel:
```bash
nxc smb 10.0.2.10 -u fcastle -p Password1 -d MARVEL.local
```
Fallback without Tailscale: `access_mode = "public"` in tfvars gives public IPs locked to your
/32, and `make azure-myip` keeps that rule following you.

**Stop paying when idle** (keeps the disks, stops compute billing):
```bash
make azure-stop      # az vm deallocate on all lab VMs
make azure-start     # resume
```
**Nuke it:** `./destroy-azure.sh`

> **Routed vs broadcast attacks:** from home over the tunnel you can run
> everything that's *routed* — LDAP enum, BloodHound, Kerberoasting, DCSync,
> pass-the-hash, psexec. The *broadcast* attacks (LLMNR/NBT-NS poisoning,
> NTLM relay, mitm6) need layer-2 adjacency and won't cross the internet — and
> Azure VNets drop broadcast/multicast entirely, so practise those on the local
> Vagrant path (see [security model](documentation/security-model.md)).

### Local (VirtualBox)
```bash
make up-local        # vagrant up (3 VMs) + ansible (the domain)
make destroy-local
```
Tight on disk? `cd vagrant && vagrant up hydra-dc` brings them up one at a time.

Prerequisites: `make deps` once to install the Ansible collections. `make help` lists all targets.

---

## Repo layout

```
ansible/
  group_vars/all.yml          # ← the entire lab definition
  site.yml                    # master playbook (DC first, then workstations)
  roles/
    domain_controller/        # promote forest, AD CS, users, SPN, share, GPO
    domain_member/            # static IP+DNS, domain join, local admin, weakenings
  inventory/vagrant.ini       # (azure_generated.yml is written by Terraform)
vagrant/Vagrantfile           # local VirtualBox path
terraform/*.tf                # Azure path (RG, VNet, NSG, 3 VMs, WinRM)
terraform/scripts/            # per-VM bootstrap (WinRM/HTTPS; Tailscale subnet router on the DC)
scripts/azure-preflight.py    # size / disk-controller / quota checks
scripts/tailnet-check.py      # Kali + subnet-router tunnel checks (make azure-tailnet)
scripts/azure-myip.sh         # make azure-myip (public-mode fallback)
documentation/                # setup guide, runbook, troubleshooting, security model
Makefile                      # one-command entrypoints (make help)
```

---

## Cost note (Azure)

Defaults are sized for a 4-vCPU (Free Trial / Student) quota: DC `Standard_D2als_v7`
(2 vCPU) + 2 × `Standard_F1as_v7` (1 vCPU). Compute bills only while running — **deallocate when
idle** and stopped VMs cost just disk. By default nothing is reachable from the internet: access
is only through your tailnet, and the tailnet policy confines the lab. See
[security model](documentation/security-model.md).

---

## Design notes

- **Why Ansible as the shared layer?** It configures Windows over WinRM identically whether the VM
  is local (Vagrant) or in Azure (Terraform). Write the AD logic once, deploy anywhere.
- **Idempotent:** re-running the playbook converges to the same state rather than erroring.
- **Order enforced:** the DC play fully completes (promotion + reboot) before workstations attempt
  to join — the `microsoft.ad.domain`/`membership` modules handle the reboots.
- **Same subnet on purpose:** both paths put all hosts in `10.0.2.0/24`. Locally that gives
  LLMNR/NBT-NS poisoning and relay the layer-2 adjacency they need (Azure can't carry broadcast).
- **One privileged credential:** domain joins + AD CS run as `lab_admin_user` (`MARVEL\tstark`)
  from `group_vars/all.yml`, so nothing depends on the platform's built-in Administrator.

Full docs: [`documentation/`](documentation/README.md).

---

*Built as IaC practice alongside PNPT prep. Teardown-and-rebuild in minutes, local or cloud.*
