# Attack chains — how each misconfiguration works

For every planted weakness: what it is, where it lives in this repo, how it is
abused, and how a defender would detect and fix it. Use this after the
walkthrough to understand *why* each step works.

---

## 1. Kerberoasting

**What.** Any authenticated principal can request a Kerberos service ticket
(TGS) for any account that has a Service Principal Name. Part of that ticket is
encrypted with the service account's password hash, so it can be cracked offline
with no lockout risk.

**Planted by.** `roles/vuln_kerberoast` sets SPNs on `svc_mssql`
(`MSSQLSvc/srv01.vuln.local:1433`). The password `Summer2024` is a dictionary
word plus a year — trivially crackable.

**Abuse.** `GetUserSPNs.py -request` → `hashcat -m 13100`.

**Detect.** Event `4769` (TGS request) with `Ticket Encryption Type 0x17`
(RC4) for accounts that don't normally request their own tickets; a spike of
4769s from one host.

**Fix.** Use `gMSA` (group Managed Service Accounts) or 25+ character random
passwords; require AES; monitor SPN-bearing accounts.

---

## 2. AS-REP Roasting

**What.** If an account has *"Do not require Kerberos pre-authentication"* set,
the KDC will hand out an AS-REP encrypted with the account's key to anyone who
asks — no password needed. Crack it offline.

**Planted by.** `roles/vuln_asrep` sets `DoesNotRequirePreAuth` on `svc_backup`
(password `Backup2023`).

**Abuse.** `GetNPUsers.py ... -no-pass` → `hashcat -m 18200`.

**Detect.** Event `4768` with pre-auth type `0`; audit
`userAccountControl` bit `0x400000` (`DONT_REQ_PREAUTH`).

**Fix.** Remove the flag; it is almost never legitimately required.

---

## 3. ACL abuse — GenericAll over a group

**What.** `GenericAll` (full control) over a group object lets the trustee
change the group's membership. If the group is privileged, that is a
privilege-escalation primitive.

**Planted by.** `roles/vuln_acl_dcsync` runs
`dsacls "<IT Admins DN>" /G VULN\svc_mssql:GA`. So cracking `svc_mssql` (from
Kerberoast) yields control of the `IT Admins` group.

**Abuse.** `net rpc group addmem "IT Admins" svc_mssql` (or
`Add-ADGroupMember`) to add a controlled principal.

**Detect.** Event `4728`/`4756` (member added to a security-enabled group);
BloodHound edge `GenericAll`/`AddMember` to a high-value group; periodic ACL
audits with `Get-Acl`/`dsacls`.

**Fix.** Remove the excessive ACE; apply the AD tiering model; protect
privileged groups with `AdminSDHolder`.

---

## 4. DCSync (replication rights)

**What.** The extended rights *DS-Replication-Get-Changes* and
*...-Get-Changes-All* on the domain head let a principal ask a DC to replicate
secrets — including password hashes — exactly as `mimikatz`/`secretsdump`
"DCSync" does.

**Planted by.** `roles/vuln_acl_dcsync` grants both rights to the `IT Admins`
group on `DC=vuln,DC=local` via `dsacls ... /G "VULN\IT Admins:CA;..."`. Chained
with step 3, membership in `IT Admins` = DCSync = full domain compromise.

**Abuse.** `secretsdump.py -just-dc-user krbtgt` / `-just-dc-user Administrator`,
then pass-the-hash or a golden ticket.

**Detect.** Event `4662` where the accessed object is the domain head and the
GUID is a replication right, from a non-DC principal.

**Fix.** Only DCs and intended sync accounts should hold replication rights;
remove the ACE from `IT Admins`.

---

## 5. ADCS ESC1 (enrollee-supplied SAN)

**What.** A certificate template that (a) grants a Client Authentication EKU,
(b) lets the requester supply the Subject Alternative Name
(`ENROLLEE_SUPPLIES_SUBJECT`), (c) requires no manager approval, and (d) allows
low-privileged enrollment, lets any domain user request a certificate *as any
user* (e.g. a Domain Admin) and then authenticate with it.

**Planted by.** `roles/vuln_adcs_esc1` creates the `VulnUserESC1` template with
`msPKI-Certificate-Name-Flag = 0x1`, Client Auth EKU, no approval, and grants
Enroll to `VULN\Domain Users`, then publishes it on the CA.

**Abuse.** `certipy-ad req ... -template VulnUserESC1 -upn Administrator@vuln.local`
then `certipy-ad auth -pfx administrator.pfx`.

**Detect.** CA audit for certificates issued with a SAN that differs from the
requester; templates where `msPKI-Certificate-Name-Flag` has
`ENROLLEE_SUPPLIES_SUBJECT` and enrollment is broad; run `certipy find
-vulnerable` yourself.

**Fix.** Remove `ENROLLEE_SUPPLIES_SUBJECT`, require manager approval, restrict
enrollment, and enable the strong-certificate-mapping enforcement
(KB5014754).

---

## Chain summary

```
Chain 1 (main):
  pivot creds (helpdesk)
      └─> Kerberoast svc_mssql ──► crack Summer2024
              └─> GenericAll on "IT Admins" ──► add self
                      └─> IT Admins has DCSync ──► dump krbtgt/Administrator
                              └─> Domain Admin  ✔ domain_pwned

Chain 1b (warm-up, parallel):
  AS-REP roast svc_backup ──► crack Backup2023

Bonus (independent):
  any Domain User ──► ESC1 template ──► cert as Administrator ──► Domain Admin
```
