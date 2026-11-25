# Security model

The lab is **deliberately vulnerable**, and its passwords are public: they're in the course and
in this repo. Its safety therefore comes entirely from **who can reach it**, never from the
hosts themselves.

## Exposure by access mode

| | `tailscale` (default) | `public` (fallback) |
|---|---|---|
| Public IPs on lab VMs | **none** | 3 × Standard static IPs |
| Inbound rules from the internet | **none** (deny at 4000, Azure deny at 65500) | your `/32` only, on mgmt + AD ports |
| How you get in | WireGuard tunnel to HYDRA-DC (subnet router); both ends connect outbound only | directly to the public IPs |
| Fails safe if your IP changes | yes: the tunnel doesn't care about IPs | yes: you're locked out until `make azure-myip` |
| Exposed to your ISP's next customer / CGNAT neighbours | no | yes, until you update the rule |
| Who else can reach it | only what your **tailnet policy** allows | anyone behind your public IP |

### NSG rules (`nsg-adlab`, on the subnet)

| Pri | Rule | Mode | Ports | Source |
|---|---|---|---|---|
| 100 | AllowMgmtFromMe | public | TCP 3389, 5986 | `allowed_source_ip` (/32) |
| 110 | AllowADAttackFromMe | public | 53, 88, 135, 139, 389, 445, 464, 636, 3268, 3269, 49152-65535 | `allowed_source_ip` (/32) |
| 120 | AllowIntraSubnet | both | * | 10.0.2.0/24 |
| 130 | AllowTailnetViaDC | tailscale | * | 100.64.0.0/10. It can only arrive through the DC's tunnel: with no public IPs, nothing else can deliver it. |
| 4000 | DenyInternetInbound | both | * | `Internet` service tag |
| 65000+ | Azure defaults | both | VNet / Azure LB allow, then **DenyAllInBound** | |

- No rule uses `0.0.0.0/0`, `*` or `Internet` as an *allow* source.
- `allowed_source_ip` has a Terraform validation that only accepts a single `/32`.
- WinRM over plain HTTP (5985) is never opened.
- The explicit deny at 4000 means a careless allow rule added later at a priority above 4000
  can't open the lab.

Audit what's live:

```bash
az network public-ip list -g rg-adlab-marvel -o table          # tailscale mode: empty
az network nsg rule list -g rg-adlab-marvel --nsg-name nsg-adlab \
  --query "[].{name:name,prio:priority,access:access,src:sourceAddressPrefix}" -o table
```

### In tailscale mode, the tailnet policy is the perimeter

HYDRA-DC joins **your** tailnet. Under Tailscale's default allow-all policy, a compromised DC
could reach your other devices. The policy in [tailscale.md §2](tailscale.md#2-one-time-lock-down-your-tailnet-policy-do-this-before-the-first-deploy):

- confines the DC with `tag:adlab`,
- lets only your own devices reach `tag:adlab` and `10.0.2.0/24`,
- grants **nothing** with the lab as the source.

Apply it **before** the first deploy.

### Outbound

The VMs have outbound internet: Azure default outbound access, or the optional NAT gateway.
HYDRA-DC needs it for Tailscale, and Windows needs it for activation and updates. A
compromised lab VM could therefore reach the internet. Deallocate the lab when you're not
using it, and don't store anything you care about on it.

## No secrets in this repository

The repository is safe to publish. **It contains no secrets and no personal data**:
- Every user-specific value (your public IP, VM admin password, Tailscale auth key, region and
  resource group) is entered at runtime with `make setup`, and written only to gitignored
  files: `terraform/terraform.tfvars` and `.secrets/`.
- Generated files that contain IPs or credentials are gitignored too: the Ansible inventory,
  `ATTACK_FROM_KALI.txt`, Terraform state and plans, and `*.bak`.
- Tracked files use placeholders only: `203.0.113.45/32` (RFC 5737 documentation range) and
  `<SET_AT_RUNTIME>`.
- `make audit` scans the working tree **and all git history** and fails if anything leaks.
- The lab's domain passwords in `ansible/group_vars/all.yml` (`fcastle:Password1`, …) are
  **intentionally public**. They are the vulnerable-lab scenario, not secrets.

## Where your secrets live locally

| Secret | Where | Protection |
|---|---|---|
| VM admin password | `terraform/terraform.tfvars`, `ansible/inventory/azure_generated.yml`, Terraform state | All gitignored. tfvars and the inventory are mode 0600. The tfvars variable is `sensitive`. |
| Tailscale auth key | `.secrets/tailscale-authkey` (written by `make setup`), passed to Terraform as an env var, the Run Command's protected parameter `TsAuthKey`, Terraform state | All gitignored. Never written to tfvars or into the script text. Encrypted in transit to the VM and not shown in the Run Command's properties or instance view. Short expiry; revoke and delete it after the build if you like. |
| Lab domain passwords | `ansible/group_vars/all.yml` (committed) | **Intentionally public.** They're the training scenario. Never reuse them. |

Check that nothing sensitive is tracked:

```bash
make audit                                                                   # full history + tree scan
git ls-files | grep -iE 'tfvars|tfstate|bak|azure_generated|ATTACK_FROM|tskey|pem|key'   # prints nothing
```

## Deallocate when idle

`make azure-stop` after each session, and `./destroy-azure.sh` when you've finished the course.
A deallocated VM isn't running, so there's nothing on it to reach.

## What works remotely vs. what needs layer-2 access

| Works over the tunnel / internet (routed) | Needs layer-2 / broadcast |
|---|---|
| SMB/LDAP enumeration, BloodHound | LLMNR / NBT-NS poisoning (Responder) |
| Kerberoasting, AS-REP roasting | SMB / NTLM relay driven by poisoning |
| Pass-the-hash / password, psexec / wmiexec | mitm6 (IPv6 DNS takeover) |
| DCSync, AD CS enumeration | Anything that relies on broadcast or multicast |

Neither the internet nor a Tailscale tunnel (which works at layer 3) carries broadcast or
multicast traffic. Azure VNets don't carry it either, so even a VM inside the subnet wouldn't
receive LLMNR or NBT-NS. Practise those attacks on the local [Vagrant path](local-vagrant.md).
