# Documentation

| Doc | What's in it |
|---|---|
| [overview.md](overview.md) | What the PNPT / PEH `MARVEL.local` lab is, and how the Azure build is put together |
| [vulnerabilities.md](vulnerabilities.md) | **The deliberate weaknesses** — per item: where it's configured, the intended attack, the real-world mitigation |
| [setup/setup-guide.md](setup/setup-guide.md) | Prerequisites, `az login`, **`make setup`** (runtime values → gitignored files) |
| [runbook.md](runbook.md) | Deploy, verify from Kali, deallocate/start, destroy |
| [troubleshooting.md](troubleshooting.md) | Image SKUs, VM sizes/quota, WinRM timing, the domain-join credential, clock skew |
| [tailscale.md](tailscale.md) | **Default access:** no public IPs. Kali setup, tailnet policy, auth key, verify, fallback |
| [security-model.md](security-model.md) | Exposure per access mode, NSG rules, secrets, routed vs broadcast attacks |
| [local-vagrant.md](local-vagrant.md) | The local VirtualBox path (same Ansible config) |

> **No secrets live in this repo.** Your IP, VM password, Tailscale key and region are entered
> at runtime by `make setup` and stored only in gitignored files. Check with `make audit`.

TL;DR:

```bash
az login
sudo tailscale up --accept-routes          # once; plus the tailnet policy in tailscale.md
make setup                 # interactive: mode, region/RG, IP, VM password, Tailscale key
./deploy-azure.sh          # build + configure (~30-40 min)
make audit                 # before any git push: tree + full history scan
make azure-tailnet         # check the tunnel
make azure-myip            # public-mode fallback: follow your IP
make azure-stop            # deallocate when idle
make azure-start           # resume
./destroy-azure.sh         # delete everything
```
