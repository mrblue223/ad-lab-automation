# Overview

## What the lab is

This repo rebuilds the Active Directory environment from TCM Security's **Practical Ethical
Hacking (PEH)** course, the one used to prepare for the **PNPT**: a small forest called
`MARVEL.local`. It is **deliberately vulnerable**. It exists so you can practise AD attacks
against infrastructure you own. The repo only *deploys* the lab; it contains no attack write-ups.

| Host | Role | OS (Azure default) | Private IP |
|---|---|---|---|
| HYDRA-DC | Domain controller for `MARVEL.local`, DNS, AD CS (Enterprise Root CA `MARVEL-HYDRA-DC-CA`) | Windows Server 2022 Datacenter: Azure Edition | 10.0.2.10 |
| THEPUNISHER | Domain-joined workstation | Windows 11 Pro 25H2 (or Server, as a fallback) | 10.0.2.11 |
| SPIDERMAN | Domain-joined workstation | Windows 11 Pro 25H2 (or Server, as a fallback) | 10.0.2.12 |

| User | Notes |
|---|---|
| `tstark` / `P@$$w0rd` | Domain Admin. Like the course's copy of Administrator, he is also in Enterprise Admins, Schema Admins and Group Policy Creator Owners. |
| `fcastle` / `Password1` | Standard user, **local admin on both workstations** |
| `pparker` / `Password2` | Standard user |
| `SQL_Service` / `MYpassword123#` | **Domain Admin** service account: **SPN** `HYDRA-DC/SQL_Service.MARVEL.local:60111`, **RC4-only** (`msDS-SupportedEncryptionTypes = 4`) so the roast returns a crackable `$krb5tgs$23$` ticket, and **password stored in its Description** |

The weaknesses are intentional. All passwords are set to never expire. SMB signing is not
required on the workstations. Defender is disabled (by a GPO plus a local setting), the
workstation **and DC** firewalls are off, and LLMNR is left on. There is also an open
`\\HYDRA-DC\hackme` share. The full catalogue — intended attack and real-world mitigation per
item — is in [vulnerabilities.md](vulnerabilities.md).

**Single source of truth:** all of the above is defined in
[`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml). Change something there once and
both deploy paths (Azure and Vagrant) pick it up.

## Cloud architecture

Default `access_mode = "tailscale"`: **no public IPs and no inbound internet rules**.

```
 Home Kali                                 Azure  ─ rg-adlab-marvel (eastus)
 ─────────                                 ──────────────────────────────────────────────────
 deploy-azure.sh ──terraform──► ARM API    vnet-adlab 10.0.2.0/24 ── snet-adlab
                                             nsg-adlab: 120 allow 10.0.2.0/24
 tailscale0 (--accept-routes)                         130 allow 100.64.0.0/10 (tailnet, via DC)
   │                                                  4000 DENY Internet   65500 DenyAll
   │  WireGuard, outbound-only both ends     rt-adlab: 100.64.0.0/10 → 10.0.2.10 (return path)
   └──────────────────────────────────►    ┌───────────────────┬──────────────┬──────────────┐
   ansible  (WinRM/HTTPS 5986, NTLM)       │ HYDRA-DC          │ THEPUNISHER  │ SPIDERMAN    │
   nxc / impacket / bloodhound             │ 10.0.2.10         │ 10.0.2.11    │ 10.0.2.12    │
   → 10.0.2.x directly                     │ Tailscale subnet  │ no agent     │ no agent     │
                                           │ router, tag:adlab │              │              │
                                           │ D2als_v7          │ F1as_v7      │ F1as_v7      │
                                           └───────────────────┴──────────────┴──────────────┘
                                             outbound: Azure default outbound access (or NAT gateway)
```

The fallback, `access_mode = "public"`, gives each VM a Standard public IP and adds NSG rules
admitting only `allowed_source_ip` (/32). See [security-model.md](security-model.md) and
[tailscale.md](tailscale.md).

### Build pipeline (what `./deploy-azure.sh` does)

1. **Pre-flight.** Checks the tools and pywinrm, confirms you're logged in with `az`, and installs
   the Ansible collections.
2. **Setup check.** Refuses to run unless `make setup` has written `terraform/terraform.tfvars`.
   The deploy never prompts for, or writes, your personal values; only `make setup` and
   `make azure-myip` do, and only into gitignored files.
3. **Image, size and quota pre-flight** (read-only `az` queries).
4. **Access pre-flight.**
   - *tailscale:* your Kali is logged in and accepting routes; the one-time auth key is read
     from `.secrets/tailscale-authkey` (written by `make setup`), or `TS_AUTHKEY`.
   - *public:* your current IP is used for this run if it has changed.
5. **Terraform.** Creates the RG, VNet, NSG, route table, 3 NICs with static private IPs, and
   3 VMs (Trusted Launch). A managed Run Command (`lab-bootstrap`, a plain `.ps1`; its exit
   code fails the apply if the script fails) runs
   [`terraform/scripts/bootstrap.ps1.tftpl`](../terraform/scripts/bootstrap.ps1.tftpl), which
   sets up WinRM over HTTPS on 5986. On HYDRA-DC it also installs Tailscale, joins your
   tailnet, advertises `10.0.2.0/24`, and turns on IP forwarding. Terraform writes the Ansible
   inventory (`azure_generated.yml`, mode 0600, with 10.0.2.x addresses in tailscale mode) and
   `ATTACK_FROM_KALI.txt`.
6. **Tunnel and WinRM wait.** Waits until HYDRA-DC is online in your tailnet *and* the route is
   approved and installed on your Kali. Then waits for TCP 5986 on every VM and runs a real
   `win_ping`. On failure it prints diagnostics.
7. **Ansible** (`site.yml`):
   - **DC play:** promote the forest, then wait for ADWS, set DNS, **keep the tailnet address
     out of AD DNS**, add the Azure forwarder, create users, groups and the SPN, set up AD CS,
     the share and the Defender GPO.
   - **Workstation play:** point DNS at the DC, wait for the SRV record, rename, join as
     `MARVEL\tstark`, add `fcastle` as local admin, then apply the weakenings.
8. **Smoke test.** Runs `nxc smb` as fcastle and prints the cheat-sheet.

### Design decisions

- **Only the DC runs Tailscale.** It routes the lab subnet, so the workstations have no agent,
  and you reach every host at its course IP. Its 100.x address is kept out of AD DNS, because a
  multi-homed DC must not advertise an address the workstations can't route to.
- **Guest NICs stay on DHCP.** Azure delivers each NIC's static private IP through a DHCP
  reservation, so the roles only set DNS. Assigning a static IP inside the VM breaks Azure
  networking.
- **One privileged credential.** The workstation joins and the AD CS setup run as `tstark`,
  defined in `group_vars/all.yml`. It works identically on Azure and Vagrant (see
  [troubleshooting](troubleshooting.md#domain-join-fails--bad-credentials)).
- **Idempotent.** Every task checks the current state before changing anything. Re-running
  `site.yml` converges and reports `changed=0` once everything is in place.
