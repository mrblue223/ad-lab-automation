# Runbook

## Deploy

Before the **first** deploy, in tailscale mode (the default), do the one-time steps in
[tailscale.md](tailscale.md): Tailscale on your Kali with `--accept-routes`, the **tailnet
policy**, and an auth key.

```bash
make setup                 # once: access mode, region/RG, IP, VM password, Tailscale key
./deploy-azure.sh          # refuses to run until setup is done
```

Later runs don't need the Tailscale key. Re-run `make setup` whenever you want to change a value.

Expect about 10 minutes for Terraform and 20–30 minutes for Ansible. DC promotion, AD CS and
the workstation joins each involve a reboot. Every step is idempotent, so if something fails
partway, fix the cause and **simply re-run the script**.

Environment overrides:

| Variable | Use |
|---|---|
| `TS_AUTHKEY=tskey-auth-...` | Use this key for one run instead of the one stored by `make setup` |
| `ALLOWED_IP=203.0.113.45` | public mode: skip IP auto-detection |
| `WINRM_TIMEOUT=1800` | Wait longer for the tunnel and WinRM (default 1200 s) |

To re-run only the configuration step:

```bash
make configure INV=azure_generated.yml
```

## Verify from Kali

In tailscale mode the addresses are the course's own. In public mode, use the public IPs from
`ATTACK_FROM_KALI.txt`.

```bash
make azure-tailnet                                   # tunnel healthy? (tailscale mode)
DC=10.0.2.10; PUN=10.0.2.11; SPI=10.0.2.12
echo "$DC hydra-dc.marvel.local hydra-dc marvel.local" | sudo tee -a /etc/hosts
```

| Check | Command | Expected |
|---|---|---|
| Domain is up, fcastle authenticates | `nxc smb $DC -u fcastle -p Password1 -d MARVEL.local` | `[+] MARVEL.local\fcastle:Password1`, `(name:HYDRA-DC) (domain:MARVEL.local)` |
| Workstations joined, fcastle is local admin | `nxc smb $PUN $SPI -u fcastle -p Password1 -d MARVEL.local` | `(Pwn3d!)` on both |
| SMB signing not required on workstations | `nxc smb $PUN $SPI` | `(signing:False)` (the DC shows `signing:True`, as in the course) |
| Users + Description finding | `nxc ldap $DC -u fcastle -p Password1 -d MARVEL.local --users` | 4 lab users; SQL_Service description shows its password |
| SPN present (Kerberoastable) | `impacket-GetUserSPNs -dc-ip $DC MARVEL.local/fcastle:Password1` | `HYDRA-DC/SQL_Service.MARVEL.local:60111   SQL_Service` |
| Share | `nxc smb $DC -u fcastle -p Password1 -d MARVEL.local --shares` | `hackme` listed |
| AD CS | `nxc ldap $DC -u fcastle -p Password1 -d MARVEL.local -M adcs` | `MARVEL-HYDRA-DC-CA` found |
| tstark is DA | `nxc smb $DC -u tstark -p 'P@$$w0rd' -d MARVEL.local` | `(Pwn3d!)` |

If the Kerberos-based checks fail with `KRB_AP_ERR_SKEW`, see
[clock skew](troubleshooting.md#clock-skew-krb_ap_err_skew).

## Pause to save credits

A deallocated VM stops billing for compute. You keep paying for the disks (a few dollars a
month). Public mode also bills for its 3 Standard static IPs; tailscale mode has none.

```bash
make azure-stop            # az vm deallocate on every VM in rg-adlab-marvel
make azure-start           # resume
```

After `azure-start`, give it 2–3 minutes: HYDRA-DC rejoins your tailnet by itself and the DC
services start. You don't need to re-run Ansible.

**Your home IP changed?**
- *tailscale mode:* nothing to do. The tunnel doesn't depend on your IP.
- *public mode:* run `make azure-myip` (or `make setup`). It updates `allowed_source_ip` in the
  gitignored tfvars (keeping a gitignored `.bak`), then shows the NSG plan and asks you to
  confirm.

## Before pushing to GitHub

```bash
make audit                 # every commit on every ref + the working tree; exit 1 on any finding
```

It loads your real IP, VM password, Tailscale key and git identity **by value** from the
gitignored files and your git config, and checks they appear nowhere. It also looks for
key/token patterns, emails and non-documentation public IPs, and never prints a value. To check
extra personal strings (your handle, your email), list them one per line in
`.secrets/audit-strings`, which is gitignored.

## Destroy

```bash
./destroy-azure.sh         # asks you to type the RG name;  ./destroy-azure.sh -y  to skip
```

This deletes every resource in the lab RG and removes the generated inventory and
`ATTACK_FROM_KALI.txt`. In tailscale mode, also remove `marvel-hydra-dc` from your tailnet's
**Machines** page (the script reminds you). If the Terraform state is lost, delete the RG directly with
`az group delete -n rg-adlab-marvel`.
