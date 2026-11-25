#!/usr/bin/env python3
"""Pre-flight checks for deploy-azure.sh (read-only Azure queries).

Checks, for the chosen region:
  * both VM sizes are offered to this subscription (not restricted)
  * the chosen disk controller (NVMe/SCSI) is supported by both sizes
  * enough regional + per-family vCPU quota is free   (skipped with --skip-quota)

Exit 0 = OK; exit 1 = problem (message on stderr).
"""
import argparse
import json
import subprocess
import sys


def az(*args):
    out = subprocess.run(["az", *args, "-o", "json"], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"az {' '.join(args)} failed:\n{out.stderr.strip()}")
    return json.loads(out.stdout)


def cap(sku, name, default=None):
    for c in sku.get("capabilities") or []:
        if c["name"] == name:
            return c["value"]
    return default


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--location", required=True)
    p.add_argument("--dc-size", required=True)
    p.add_argument("--ws-size", required=True)
    p.add_argument("--ws-count", type=int, required=True)
    p.add_argument("--disk-controller", required=True)
    p.add_argument("--skip-quota", action="store_true")
    a = p.parse_args()

    wanted = {a.dc_size, a.ws_size}
    skus = {
        s["name"]: s
        for s in az("vm", "list-skus", "-l", a.location, "--resource-type", "virtualMachines")
        if s["name"] in wanted
    }

    problems = []
    for size in sorted(wanted):
        s = skus.get(size)
        if not s:
            problems.append(f"{size}: not offered in {a.location}")
            continue
        if s.get("restrictions"):
            reasons = ", ".join(r.get("reasonCode", "?") for r in s["restrictions"])
            problems.append(f"{size}: restricted for this subscription ({reasons})")
        if cap(s, "CpuArchitectureType", "x64") != "x64":
            problems.append(f"{size}: is {cap(s, 'CpuArchitectureType')} — Windows x64 images need an x64 size")
        ctrl = [c.strip() for c in (cap(s, "DiskControllerTypes") or "SCSI").split(",")]
        if a.disk_controller not in ctrl:
            problems.append(f"{size}: supports disk controller {'/'.join(ctrl)}, not {a.disk_controller} "
                            f"(set disk_controller_type = \"{ctrl[0]}\")")

    if problems:
        sys.exit("VM size problems:\n  " + "\n  ".join(problems) +
                 f"\nList usable sizes:\n  az vm list-skus -l {a.location} --resource-type virtualMachines "
                 "--query \"[?restrictions==\\`[]\\`].name\" -o tsv")

    print(f"  Sizes OK: DC={a.dc_size}, {a.ws_count}x WS={a.ws_size}, disk controller {a.disk_controller}")
    if a.skip_quota:
        return

    need = {}
    for size, count in ((a.dc_size, 1), (a.ws_size, a.ws_count)):
        fam = skus[size]["family"]
        need[fam] = need.get(fam, 0) + int(cap(skus[size], "vCPUs")) * count
    need["cores"] = sum(need.values())

    free = {u["name"]["value"]: int(u["limit"]) - int(u["currentValue"])
            for u in az("vm", "list-usage", "-l", a.location)}
    short = [f"{k}: need {v}, free {free.get(k, 0)}" for k, v in need.items() if v > free.get(k, 0)]
    if short:
        sys.exit("Not enough vCPU quota in " + a.location + ":\n  " + "\n  ".join(short) +
                 "\nOptions:\n"
                 "  a) smaller workstations, e.g. ws_vm_size = \"Standard_F1as_v7\" in terraform.tfvars\n"
                 "  b) request more: Portal -> Subscriptions -> Usage + quotas (not possible on Free Trial)\n"
                 "  c) a region with free quota: location = \"...\"\n"
                 f"  Check: az vm list-usage -l {a.location} -o table")
    print(f"  Quota OK: need {need['cores']} vCPUs, {free.get('cores', 0)} free in {a.location}")


if __name__ == "__main__":
    main()
