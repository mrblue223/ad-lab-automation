#!/usr/bin/env python3
"""Tailscale checks for deploy-azure.sh (local, read-only; uses the `tailscale` CLI).

  tailnet-check.py kali
      Is this machine logged in to a tailnet, and does it accept subnet routes?
  tailnet-check.py router --hostname marvel-hydra-dc --subnet 10.0.2.0/24
      Is the lab's subnet router online, and is its route approved and
      actually installed on this machine?

Exit codes: 0 ok, 1 problem (reason on stderr), 2 not ready yet (keep waiting).
"""
import argparse
import json
import subprocess
import sys


def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        sys.exit(f"`{cmd[0]}` not found. Install Tailscale: curl -fsSL https://tailscale.com/install.sh | sh")


def status():
    r = run("tailscale", "status", "--json")
    if r.returncode != 0 and not r.stdout.strip():
        sys.stderr.write(f"`tailscale status` failed: {r.stderr.strip()}\n"
                         "Is tailscaled running?  sudo systemctl enable --now tailscaled\n")
        sys.exit(1)
    return json.loads(r.stdout)


def check_kali():
    st = status()
    if st.get("BackendState") != "Running":
        sys.exit(f"Tailscale on this machine is '{st.get('BackendState')}', not Running.\n"
                 "  Log in:  sudo tailscale up --accept-routes")
    prefs = run("tailscale", "debug", "prefs")
    if prefs.returncode == 0:
        try:
            if not json.loads(prefs.stdout).get("RouteAll", False):
                sys.exit("This machine does not accept subnet routes, so 10.0.2.0/24 would be unreachable.\n"
                         "  Fix:  sudo tailscale set --accept-routes")
        except json.JSONDecodeError:
            pass
    else:
        print("  (couldn't read prefs; make sure you ran: sudo tailscale set --accept-routes)")
    me = st.get("Self", {})
    print(f"  Kali on tailnet as {me.get('HostName')} ({', '.join(me.get('TailscaleIPs', [])[:1])})")


def check_router(hostname, subnet):
    st = status()
    peers = [p for p in (st.get("Peer") or {}).values() if p.get("HostName", "").lower() == hostname.lower()]
    online = [p for p in peers if p.get("Online")]
    if not peers:
        print(f"  waiting: {hostname} has not joined the tailnet yet", file=sys.stderr)
        sys.exit(2)
    if not online:
        print(f"  waiting: {hostname} is in the tailnet but offline", file=sys.stderr)
        sys.exit(2)
    if len(peers) > 1:
        print(f"  note: {len(peers)} machines named {hostname} (old deployments?). "
              "Remove the offline ones in the admin console.", file=sys.stderr)
    p = online[0]
    if subnet not in (p.get("PrimaryRoutes") or []):
        print(f"  waiting: {hostname} is online but route {subnet} is not approved.\n"
              "    Approve it: https://login.tailscale.com/admin/machines -> "
              f"{hostname} -> Edit route settings -> {subnet}\n"
              "    (or add autoApprovers to your policy — documentation/tailscale.md)", file=sys.stderr)
        sys.exit(2)
    host = subnet.split("/")[0].rsplit(".", 1)[0] + ".10"
    route = run("ip", "route", "get", host)
    if route.returncode == 0 and "tailscale" not in route.stdout:
        sys.exit(f"Route {subnet} is approved, but this machine sends {host} via:\n  {route.stdout.strip()}\n"
                 "  Fix:  sudo tailscale set --accept-routes   "
                 "(and check no local network overlaps the lab subnet)")
    print(f"  {hostname} online ({', '.join(p.get('TailscaleIPs', [])[:1])}), routing {subnet} to this machine")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("kali")
    r = sub.add_parser("router")
    r.add_argument("--hostname", required=True)
    r.add_argument("--subnet", required=True)
    a = ap.parse_args()
    if a.cmd == "kali":
        check_kali()
    else:
        check_router(a.hostname, a.subnet)


if __name__ == "__main__":
    main()
