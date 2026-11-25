#!/usr/bin/env python3
"""make audit — prove the repo (working tree AND all git history) holds no
personal data or secrets before you push.

Contains no user-specific values itself. At runtime it loads, BY VALUE, the
things that must never be committed, and searches every blob of every commit
on every ref, every commit message, the commit identities, and the working tree:

  * admin_password and allowed_source_ip from terraform/terraform.tfvars
  * the Tailscale key in .secrets/tailscale-authkey
  * your git identity (user.name / user.email from git config)
  * any extra strings you list, one per line, in .secrets/audit-strings
    (e.g. your handle or email) — that file is gitignored

plus generic patterns: tskey-*, private-key blocks, common cloud/API tokens,
GUIDs (Azure subscription/tenant ids), email addresses, and public IPv4s
outside the RFC 5737 documentation / private ranges.

Values are never printed — only where they were found.
Exit 0 = clean; 1 = findings in tracked content or history.
"""
import ipaddress
import os
import re
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def git(*a):
    return subprocess.run(["git", "-C", REPO, *a], capture_output=True, text=True, errors="replace").stdout


def tfvar(text, key):
    m = re.search(r'^\s*' + key + r'\s*=\s*"((?:[^"\\]|\\.)*)"', text, re.M)
    return m.group(1).replace('\\"', '"').replace("\\\\", "\\") if m else ""


# ---- values that must never appear (loaded at runtime, never printed) -------
needles = {}
tfv = os.path.join(REPO, "terraform", "terraform.tfvars")
if os.path.exists(tfv):
    t = open(tfv, encoding="utf-8", errors="replace").read()
    if (pw := tfvar(t, "admin_password")) and len(pw) >= 6:
        needles["VM admin password"] = pw
    if ip := tfvar(t, "allowed_source_ip").split("/")[0]:
        needles["your allowed_source_ip"] = ip
keyf = os.path.join(REPO, ".secrets", "tailscale-authkey")
if os.path.exists(keyf):
    if k := open(keyf).read().strip():
        needles["Tailscale auth key"] = k
for scope in ("--global", "--system"):
    for field in ("user.name", "user.email"):
        v = subprocess.run(["git", "config", scope, "--get", field], capture_output=True, text=True).stdout.strip()
        if v and v not in ("...",) and len(v) >= 4:
            needles[f"git {field} ({scope[2:]})"] = v
extra = os.path.join(REPO, ".secrets", "audit-strings")
if os.path.exists(extra):
    for i, line in enumerate(open(extra, encoding="utf-8"), 1):
        if (v := line.strip()) and not v.startswith("#") and len(v) >= 4:
            needles[f"audit-strings line {i}"] = v

PATTERNS = {
    "Tailscale key": re.compile(r"tskey-(?:auth|client|api)-[A-Za-z0-9]{6,}-[A-Za-z0-9]{10,}"),
    "private key block": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "API token": re.compile(r"\b(ghp_[A-Za-z0-9]{30,}|github_pat_\w{20,}|AKIA[0-9A-Z]{16}|xox[bap]-[\w-]{10,}|AIza[\w-]{35})"),
    "GUID (subscription/tenant id?)": re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I),
    "email address": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
}
OK_EMAILS = re.compile(r"^(noreply@anthropic\.com|.*@example\.(com|org|net)|.*@users\.noreply\.github\.com)$")
IPV4 = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])")
DOC = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
OK_IPS = {"168.63.129.16"}   # Azure platform resolver/wire server — generic, documented


def public_ip(s):
    try:
        ip = ipaddress.IPv4Address(s)
    except ValueError:
        return False
    return ip.is_global and not ip.is_multicast and not any(ip in n for n in DOC) and s not in OK_IPS


def scan(text):
    hits = []
    for name, val in needles.items():
        if val in text:
            hits.append(name)
    for name, rx in PATTERNS.items():
        for m in rx.finditer(text):
            if name == "email address" and OK_EMAILS.match(m.group(0)):
                continue
            hits.append(name)
    for m in IPV4.finditer(text):
        if public_ip(m.group(1)):
            hits.append(f"public IPv4 {m.group(1) if m.group(1) not in needles.values() else '(your IP)'}")
    return sorted(set(hits))


bad = []
refs = git("rev-list", "--all").split()
seen = set()
for c in refs:
    for line in git("ls-tree", "-r", c).splitlines():
        meta, path = line.split("\t", 1)
        sha = meta.split()[2]
        if sha in seen:
            continue
        seen.add(sha)
        for h in scan(git("cat-file", "-p", sha)):
            bad.append(("history", f"{path} (blob {sha[:7]}, first seen in {c[:7]})", h))
    msg = git("log", "-1", "--format=%B", c)
    for h in scan(msg):
        bad.append(("commit msg", c[:7], h))
    ident = git("log", "-1", "--format=%an <%ae> / %cn <%ce>", c)
    for name, val in needles.items():
        if name.startswith("git ") and val in ident:
            bad.append(("commit identity", c[:7], name))

for path in git("ls-files", "--cached", "--others", "--exclude-standard").splitlines():
    p = os.path.join(REPO, path)
    if os.path.isfile(p):
        for h in scan(open(p, encoding="utf-8", errors="replace").read()):
            bad.append(("working tree", path, h))

tracked_bad_names = [f for f in git("ls-files").splitlines()
                     if re.search(r"(\.tfvars$|tfstate|\.bak$|azure_generated|ATTACK_FROM|tskey|authkey|\.pem$|\.key$|\.secrets/)", f, re.I)]

print(f"Scanned {len(refs)} commits on all refs, {len(seen)} unique blobs, and the working tree.")
print(f"Value checks loaded at runtime (never printed): {', '.join(sorted(needles)) or 'none'}")
for f in tracked_bad_names:
    print(f"  TRACKED SENSITIVE-LOOKING FILE: {f}")
for where, what, h in sorted(set(bad)):
    print(f"  [{where}] {what}: {h}")
ignored_ok = [f for f in ("terraform/terraform.tfvars", ".secrets/tailscale-authkey", "ansible/inventory/azure_generated.yml",
                          "ATTACK_FROM_KALI.txt") if os.path.exists(os.path.join(REPO, f))]
if ignored_ok:
    print("Local gitignored files holding your values (expected, never committed): " + ", ".join(ignored_ok))
if bad or tracked_bad_names:
    print("FAIL: remove these before pushing (history findings need a rewrite, e.g. git filter-repo).")
    sys.exit(1)
print("PASS: no personal data or secrets in tracked files or git history.")
