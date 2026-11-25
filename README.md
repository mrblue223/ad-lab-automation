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
| THEPUNISHER | Workstation | Windows 10/11 | 10.0.2.11 |
| SPIDERMAN | Workstation | Windows 10/11 | 10.0.2.12 |

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

From your Kali (needs `az`, `terraform`, `ansible`; run `az login` first):
```bash
./deploy-azure.sh
```
That's it. The script:
1. detects your public IP and locks the lab firewall to it
2. `terraform apply` → VNet + DC + 2 workstations + WinRM
3. **auto-generates** the Ansible inventory (no copy/paste)
4. waits for WinRM, then Ansible builds the whole domain
5. prints `ATTACK_FROM_KALI.txt` with the public IPs and ready-to-run commands

Then attack straight from your home Kali:
```bash
nxc smb <dc-public-ip> -u fcastle -p Password1 -d MARVEL.local
```

**Stop paying when idle** (keeps the disks, stops compute billing):
```bash
az vm deallocate --ids $(az vm list -g rg-adlab-marvel --query "[].id" -o tsv)
az vm start      --ids $(az vm list -g rg-adlab-marvel --query "[].id" -o tsv)   # resume
```
**Nuke it:** `./destroy-azure.sh`

> **Routed vs broadcast attacks:** from home over the internet you can run
> everything that's *routed* — LDAP enum, BloodHound, Kerberoasting, DCSync,
> pass-the-hash, psexec. The *broadcast* attacks (LLMNR/NBT-NS poisoning,
> NTLM relay, mitm6) need layer-2 adjacency and won't cross the internet — for
> those, deploy a Kali in-Azure on the same subnet (see `docs/deploy.md`).

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
  inventory/{vagrant,azure}.ini
vagrant/Vagrantfile           # local VirtualBox path
terraform/*.tf                # Azure path (RG, VNet, NSG, 3 VMs, WinRM)
Makefile                      # one-command entrypoints
```

---

## Cost note (Azure)

~B2s VMs. With VMs **deallocated when idle**, ~$200 of credit lasts months (compute bills only
while running; stopped VMs cost just disk). Running 24/7 is ~$90–110/mo. The NSG locks RDP/WinRM
to your IP only; intra-subnet traffic is open so the broadcast attacks (LLMNR/relay) still work.

---

## Design notes

- **Why Ansible as the shared layer?** It configures Windows over WinRM identically whether the VM
  is local (Vagrant) or in Azure (Terraform). Write the AD logic once, deploy anywhere.
- **Idempotent:** re-running the playbook converges to the same state rather than erroring.
- **Order enforced:** the DC play fully completes (promotion + reboot) before workstations attempt
  to join — the `microsoft.ad.domain`/`membership` modules handle the reboots.
- **Same subnet on purpose:** both paths put all hosts in `10.0.2.0/24` so LLMNR/NBT-NS poisoning
  and SMB relay work (they need layer-2 adjacency).

---

*Built as IaC practice alongside PNPT prep. Teardown-and-rebuild in minutes, local or cloud.*
