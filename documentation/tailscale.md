# Tailscale access (default: `access_mode = "tailscale"`)

The lab has **no public IPs and no inbound internet rules**. Your Kali reaches it through a
Tailscale tunnel to HYDRA-DC, which acts as a **subnet router** for `10.0.2.0/24`. You talk to
every host at its real lab IP (10.0.2.10 / .11 / .12), so the course commands work unchanged.
That includes the DC's DNS SRV records, BloodHound collection and Kerberos.

```
 Kali (home)                     Tailscale (WireGuard)            Azure VNet 10.0.2.0/24 — no public IPs
 ───────────                     ─────────────────────            ────────────────────────────────────────
 tailscale0 ──── encrypted, outbound-only from both ends ────►  HYDRA-DC  10.0.2.10  (tailscale, tag:adlab)
   route 10.0.2.0/24 via tunnel                                    │  IP forwarding
                                                                   ├──► THEPUNISHER 10.0.2.11  (no agent)
                                                                   └──► SPIDERMAN   10.0.2.12  (no agent)
                                  UDR 100.64.0.0/10 → 10.0.2.10 brings replies back through the DC
```

- Both ends only make **outbound** connections to Tailscale's coordination and relay servers.
  Nothing listens on the internet.
- Only HYDRA-DC runs the agent. The workstations are reached through it.
- The VMs reach the internet outbound through Azure's default outbound access, which is free.
  The alternative is a NAT gateway (`enable_nat_gateway = true`, about $33/month, which bills
  even while the VMs are deallocated).

---

## 1. One-time: Tailscale on your Kali

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --accept-routes --operator=$USER   # --operator: run `tailscale` without sudo
tailscale status                                    # you should see yourself
```

`--accept-routes` is **required**: without it your Kali ignores the lab subnet. If you're
already logged in, `sudo tailscale set --accept-routes` turns it on.

> If your Kali is itself a VirtualBox VM on **NAT** networking, its own network is also
> `10.0.2.0/24`, so the lab route can't win. Switch that VM to bridged networking. Check with
> `ip -4 route`: no local route should cover 10.0.2.0/24.

## 2. One-time: lock down your tailnet policy (do this BEFORE the first deploy)

The default Tailscale policy lets **every device reach every other device**. HYDRA-DC is a
deliberately vulnerable box with public passwords. Under the default policy, if it's
compromised it could reach your laptop, phone and NAS. Replace the policy at
**https://login.tailscale.com/admin/acls**:

```jsonc
{
  "tagOwners": {
    // Only tailnet admins can create machines tagged as lab machines.
    "tag:adlab": ["autogroup:admin"],
  },

  "autoApprovers": {
    // HYDRA-DC's subnet route is approved automatically (otherwise approve it by hand).
    "routes": { "10.0.2.0/24": ["tag:adlab"] },
  },

  "grants": [
    // Your own devices keep talking to each other (this replaces the default allow-all).
    { "src": ["autogroup:member"], "dst": ["autogroup:member"], "ip": ["*"] },

    // Your devices -> the lab DC and the lab subnet behind it.
    { "src": ["autogroup:member"], "dst": ["tag:adlab", "10.0.2.0/24"], "ip": ["*"] },

    // There is deliberately NO grant with tag:adlab (or 10.0.2.0/24) as the source:
    // lab machines cannot open connections to anything in your tailnet.
  ],
}
```

Afterwards, open **Access controls → Preview rules**, choose `tag:adlab`, and confirm it has
no access to any of your devices. If you share the tailnet with other people, narrow `autogroup:member` to your
own user or a group.

**Attacks that need callbacks** (the lab connecting back to your Kali, e.g. coercion into a
listener or certipy relay): give your Kali a tag and add a narrow, port-scoped grant only while
you need it.

```jsonc
"tagOwners": { "tag:adlab": ["autogroup:admin"], "tag:kali": ["autogroup:admin"] },
// ...
{ "src": ["tag:adlab", "10.0.2.0/24"], "dst": ["tag:kali"], "ip": ["tcp:80", "tcp:445"] },
```

## 3. Each fresh build: an auth key

At **https://login.tailscale.com/admin/settings/keys → Generate auth key**:

| Setting | Value | Why |
|---|---|---|
| Reusable | yes | Rebuilds and mode switches can use the same key |
| Ephemeral | **no** | Ephemeral nodes are deleted when they go offline, so a deallocate/start cycle would lose the DC |
| Pre-approved | yes | If device approval is on |
| Tags | `tag:adlab` | Must match `tailscale_tags`. Tagged nodes don't expire, and the policy above confines them. |
| Expiration | 1–7 days is plenty | The key is only used once, while the DC is bootstrapping |

Then run `make setup`, choose **tailscale**, and paste the key at step 5 (input is hidden).
It's stored in `.secrets/tailscale-authkey`: gitignored, mode 0600, never in tfvars. Then:

```bash
./deploy-azure.sh
```

(`TS_AUTHKEY=tskey-... ./deploy-azure.sh` overrides the stored key for one run.)

The key goes to Terraform only as an environment variable (`TF_VAR_tailscale_auth_key`). It is
**never written to tfvars**, and it travels to the VM in the extension's encrypted
`protected_settings`. It does end up in the local `terraform.tfstate`, which is gitignored and
marked sensitive. To be thorough, after the build revoke the key in the admin console and
delete it locally (`make setup`, step 5, or `rm .secrets/tailscale-authkey`). The DC stays
connected.

Re-runs don't need the key. The DC's bootstrap runs once, and afterwards Terraform ignores the
setting that carries the key.

## 4. Verify

```bash
make azure-tailnet            # Kali logged in + accepting routes; DC online; route approved and installed
ip route get 10.0.2.10        # → "dev tailscale0"
nxc smb 10.0.2.10-12 -u fcastle -p Password1 -d MARVEL.local
tailscale ping marvel-hydra-dc   # "via DERP(...)" = relayed (slower); "via <ip>:<port>" = direct
```

`deploy-azure.sh` runs these same checks, waits for the route, and only then runs WinRM and
Ansible. The full verification table is in the [runbook](runbook.md#verify-from-kali).

## 5. Daily use

- `make azure-stop` / `make azure-start`: HYDRA-DC reconnects to the tailnet by itself after a
  start. Give it 2–3 minutes.
- Your Kali just needs Tailscale up (`tailscale status`).
- Rebuilt from scratch? Remove the old `marvel-hydra-dc` under **Machines** first, otherwise the
  new one is named `marvel-hydra-dc-1`. The scripts cope, but it's untidy.
  `destroy-azure.sh` reminds you.

## 6. Fallback: public mode

If Tailscale is unavailable, switch to the earlier design with public IPs and the NSG locked to
your /32:

```bash
make setup             # step 1: choose "public"; step 3: confirm your detected IP
./deploy-azure.sh      # adds public IPs + NSG rules, rewrites the inventory/cheat-sheet
```

In public mode, run `make azure-myip` whenever your IP changes. It shows the NSG plan and asks
you to confirm. To return to Tailscale, run `make setup`, choose **tailscale**, and store a
key. Then run `./deploy-azure.sh`: it detects the switch and re-runs the DC's bootstrap.

## 7. Troubleshooting

| Symptom (from `deploy-azure.sh` / `make azure-tailnet`) | Fix |
|---|---|
| `Tailscale on this machine is 'NeedsLogin'` | `sudo tailscale up --accept-routes` |
| `does not accept subnet routes` | `sudo tailscale set --accept-routes` |
| `marvel-hydra-dc has not joined the tailnet yet` (until timeout) | The bootstrap failed. Read its log: `az vm run-command invoke -g rg-adlab-marvel -n HYDRA-DC --command-id RunPowerShellScript --scripts "Get-Content C:\WindowsAzure\lab-bootstrap.log -Tail 40"`. Usual causes: an expired, ephemeral or untagged key, or a tag not listed in `tagOwners`. Re-run with a new key: `TF_VAR_tailscale_auth_key=tskey-... terraform -chdir=terraform apply -replace='azurerm_virtual_machine_extension.winrm["HYDRA-DC"]'` |
| `online but route 10.0.2.0/24 is not approved` | Add the `autoApprovers` block, or approve it under **Machines → marvel-hydra-dc → Edit route settings** |
| `approved, but this machine sends 10.0.2.10 via ...` | accept-routes is off, or a local network overlaps 10.0.2.0/24 |
| The DC responds but the workstations don't | Check the UDR exists (`az network route-table route list -g rg-adlab-marvel --route-table-name rt-adlab -o table`), that IP forwarding is on for the DC's NIC, and that the DC's bootstrap log shows `Set-NetIPInterface -Forwarding Enabled` |
| Works, but slowly | Traffic is relayed through DERP because Azure's default outbound NAT blocks direct connections. Fine for a lab. `enable_nat_gateway = true` often gets you a direct path. |

## Trust note

Tailscale (the company) runs the coordination servers. Your traffic is end-to-end WireGuard,
and their servers can't read it, but they do see device metadata. If you'd rather self-host,
**Headscale** is an open-source coordination server: run `tailscale up --login-server` on the
Kali, and change the bootstrap's `up` line to match.
