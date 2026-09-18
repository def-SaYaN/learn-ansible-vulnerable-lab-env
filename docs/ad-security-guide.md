# Active Directory Security — a from-scratch, in-depth guide

This is a self-contained study guide for understanding Active Directory (AD)
and how it is attacked and defended. It is written for someone starting from
zero and building toward interview-level depth (HackTheBox / OSCP / CRTP style).
It pairs with the vulnerable lab in this repo: wherever a concept maps to a
planted vulnerability, you will see a **In this lab** note.

> **Visual companion:** open [`ad-attack-map.svg`](ad-attack-map.svg) for a one-page
> diagram of the Kerberos ticket flow and the full lab attack chain.

Read it slowly. AD attacks are not about memorizing commands — they are about
understanding a handful of protocols deeply enough that the attacks become
obvious consequences. This guide spends most of its words on the "why".

## Table of contents

1. [What Active Directory actually is](#1-what-active-directory-actually-is)
2. [The structure: forests, domains, OUs, objects](#2-the-structure-forests-domains-ous-objects)
3. [How logon works: NTLM and Kerberos](#3-how-logon-works-ntlm-and-kerberos)
4. [Credentials: passwords, hashes, keys, and tickets](#4-credentials-passwords-hashes-keys-and-tickets)
5. [Enumeration: seeing the domain like an attacker](#5-enumeration-seeing-the-domain-like-an-attacker)
6. [Attack technique catalog](#6-attack-technique-catalog)
7. [Lateral movement and code execution](#7-lateral-movement-and-code-execution)
8. [Persistence and domain dominance](#8-persistence-and-domain-dominance)
9. [Active Directory Certificate Services (ADCS)](#9-active-directory-certificate-services-adcs)
10. [Trusts and multi-domain attacks](#10-trusts-and-multi-domain-attacks)
11. [Detection and defense](#11-detection-and-defense)
12. [Tooling reference](#12-tooling-reference)
13. [Glossary](#13-glossary)
14. [How this maps to the lab + a study plan](#14-how-this-maps-to-the-lab--a-study-plan)

---

## 1. What Active Directory actually is

Active Directory is Microsoft's **directory service**: a centralized database
plus a set of protocols that let an organization manage identity and access for
many computers at once. Before AD, every Windows machine had its own local list
of users (the SAM database). That does not scale: 500 employees would mean
creating and syncing accounts on hundreds of machines. AD solves this by moving
identity into one authoritative place.

Three jobs AD does:

- **Authentication** — proving *who you are* (you log in, the domain verifies it).
- **Authorization** — deciding *what you can do* (which files, which machines).
- **Directory / management** — a searchable database of users, computers,
  groups, printers, plus a policy engine (Group Policy) to push settings.

The server role that runs AD is the **Domain Controller (DC)**. A DC:

- Holds the domain database file **`NTDS.dit`**, which contains every user and
  computer account *and their password material*. This is why the DC is the
  crown jewel: reading `NTDS.dit` = every credential in the domain.
- Runs the **KDC (Key Distribution Center)**, the Kerberos ticket-issuing
  service (more in section 3).
- Usually also runs **DNS**, because AD depends heavily on DNS to locate
  services (clients find the DC by asking DNS for special `SRV` records).

**Mental model:** the DC is the company's ID office, key-cutting shop, and
records vault combined. Compromising it fully ("domain dominance") means you can
impersonate anyone and access anything.

> **In this lab:** `dc01` is the Domain Controller and DNS server for the domain
> `vuln.local`. Every other machine trusts it and resolves names through it.

---

## 2. The structure: forests, domains, OUs, objects

AD is hierarchical. From biggest to smallest:

- **Forest** — the top-level security boundary. Everything inside one forest
  shares a common schema and global catalog. **Key security fact:** the forest,
  not the domain, is the true security boundary. If any DC in a forest is
  compromised, the whole forest should be considered compromised, because trust
  relationships and shared secrets let an attacker move between domains.
- **Domain** — an administrative and replication unit inside a forest, e.g.
  `vuln.local`. A domain has its own users, groups, and policies. Large orgs may
  have several domains (e.g. `corp.example.com` and `dev.example.com`) linked by
  **trusts**.
- **Domain tree** — a set of domains sharing a contiguous namespace
  (`example.com`, `eu.example.com`, `us.example.com`).
- **Organizational Unit (OU)** — a folder inside a domain used to organize
  objects and to apply **Group Policy** and **delegated administration**. OUs
  are not a security boundary; they are for management. Delegating rights on an
  OU (e.g. "helpdesk can reset passwords in the Staff OU") is a common source of
  privilege-escalation paths.
- **Objects** — the actual entries: **users**, **computers** (every joined
  machine has a computer account, named like `WS01$`), **groups**, **service
  accounts**, **GPOs**, etc.

Each object has a **Distinguished Name (DN)** describing its full path, e.g.
`CN=helpdesk,OU=Staff,DC=vuln,DC=local`. It also has attributes
(`sAMAccountName`, `userPrincipalName`, `memberOf`, `servicePrincipalName`,
`userAccountControl`, etc.). Attackers query these attributes constantly.

### Groups you must know

- **Domain Admins** — full control of the domain. The primary target.
- **Enterprise Admins** — full control across the whole forest (exists in the
  forest root domain).
- **Administrators** (built-in) — local admin on DCs / the domain.
- **Account Operators, Backup Operators, Server Operators, Print Operators** —
  "privileged-ish" built-in groups that are frequently abusable (e.g. Backup
  Operators can read `NTDS.dit`; Account Operators can modify many accounts).
- **DnsAdmins** — historically abusable to run code on the DC via a malicious
  DLL.

### How objects are stored and queried: LDAP

AD exposes its database over **LDAP (Lightweight Directory Access Protocol)** on
ports 389 (plain) and 636 (TLS). Almost every enumeration tool is, under the
hood, doing LDAP searches: "give me all users", "give me all accounts with an
SPN", "give me the ACL on this object". Understanding that AD *is a queryable
database* demystifies most tooling.

> **In this lab:** users live under `OU=Staff` and `OU=ServiceAccounts`, groups
> under `OU=Groups`. Look at `inventory/group_vars/all.yml` to see the exact
> objects and how they are declared as code.

---

## 3. How logon works: NTLM and Kerberos

There are two authentication protocols in AD. You must understand both, because
different attacks target different protocols.

### 3.1 NTLM (the old challenge-response protocol)

NTLM is the legacy protocol, still enabled almost everywhere for compatibility.
It is a **challenge-response** scheme and it never sends the password. Flow when
Alice authenticates to a server:

1. **Negotiate** — Alice's client tells the server it wants to use NTLM.
2. **Challenge** — the server sends a random number (the "challenge" / nonce).
3. **Response** — Alice's client encrypts the challenge using her **NT hash**
   (a hash of her password) and sends the result.
4. The server forwards this to a DC (via the Netlogon protocol) to verify,
   because only the DC knows Alice's NT hash.

Crucial consequences:

- The **NT hash is functionally the password.** If you steal the NT hash, you
  can complete step 3 without ever knowing the plaintext. This is
  **Pass-the-Hash** (section 6/7).
- The response that travels the wire (**NetNTLMv1/v2**) can be captured and
  cracked offline, or **relayed** to another server (NTLM relay).
- NTLM has no concept of mutual authentication of the *service* by default,
  which is what makes relay attacks possible.

### 3.2 Kerberos (the modern, default protocol)

Kerberos is the default in AD. It is ticket-based and avoids sending reusable
secrets around. The DC plays the role of **KDC**, which has two sub-services:
the **Authentication Service (AS)** and the **Ticket-Granting Service (TGS)**.

The single most important secret in Kerberos is the **`krbtgt` account's
password hash**. The KDC uses it to encrypt/sign tickets. Whoever holds the
`krbtgt` hash can forge any ticket (Golden Ticket, section 8).

The full dance, step by step:

**Step A — AS-REQ / AS-REP (get a TGT):**
1. Alice sends an **AS-REQ** to the KDC. To prove it is really her, she includes
   a timestamp **encrypted with her own key** (derived from her password). This
   proof is called **pre-authentication**.
2. The KDC decrypts that timestamp with Alice's key (which it knows). If it
   works, Alice proved she knows her password.
3. The KDC returns an **AS-REP** containing a **TGT (Ticket-Granting Ticket)**.
   The TGT is **encrypted with the `krbtgt` key**, so only the KDC can read it.
   Inside the TGT is a **PAC (Privilege Attribute Certificate)** listing Alice's
   group memberships (this is how authorization travels).

> **Attack seed (AS-REP Roasting):** if pre-authentication is *disabled* for an
> account, the KDC will send an AS-REP to *anyone* who asks for that account —
> and part of the AS-REP is encrypted with the account's key. Capture it, crack
> it offline. See section 6.1.

**Step B — TGS-REQ / TGS-REP (get a service ticket):**
4. When Alice wants to use a service (say the file service on `SRV01`), she
   sends a **TGS-REQ** to the KDC, presenting her TGT and naming the service by
   its **SPN (Service Principal Name)**, e.g. `CIFS/srv01.vuln.local`.
5. The KDC issues a **TGS (service ticket)** encrypted with **the service
   account's key** (the account that "owns" that SPN).

> **Attack seed (Kerberoasting):** *any* authenticated user can request a TGS
> for *any* SPN. Since the TGS is encrypted with the service account's key, and
> service accounts often have weak human-set passwords, you can request the
> ticket and crack it offline to recover the service account's password. See
> section 6.2.

**Step C — AP-REQ (use the ticket):**
6. Alice presents the TGS to the service on `SRV01`. The service decrypts it
   with its own key and reads the PAC to learn who Alice is and what groups she
   is in. Access granted.

### 3.3 Why this design leads to offline cracking

Notice the recurring theme: **something on the wire is encrypted with an
account's password-derived key.** Kerberos assumed the network was hostile and
protected tickets with encryption — but that same encryption is a crackable
oracle if the key comes from a weak password. Encryption types matter here:

- **RC4 (etype 23)** uses the NT hash directly as the key — fast to crack.
  Attackers often *downgrade* requests to RC4 on purpose.
- **AES128/256 (etype 17/18)** are slower to crack and preferred defensively.

---

## 4. Credentials: passwords, hashes, keys, and tickets

A precise vocabulary here prevents endless confusion.

- **Plaintext password** — what the human types. Rarely available directly.
- **NT hash** — `MD4(UTF-16LE(password))`. Stored in `NTDS.dit` (domain
  accounts) and the local **SAM** (local accounts). It is *unsalted*, which is
  why identical passwords produce identical hashes and why "pass-the-hash"
  works. Format seen in dumps: `user:RID:LMhash:NThash:::`.
- **LM hash** — an ancient, extremely weak hash, disabled on modern systems
  (you will see `aad3b435...` which is the "empty" LM value).
- **Kerberos keys** — AES/RC4 keys derived from the password (RC4 key == NT
  hash). Used to encrypt Kerberos pre-auth and tickets.
- **TGT** — your "logged into the domain" token, encrypted with the `krbtgt`
  key. Stealing a TGT = **Pass-the-Ticket**.
- **TGS / service ticket** — proof you may use one specific service.
- **`krbtgt` hash** — the master key for forging tickets (Golden Ticket).
- **DPAPI** — Windows Data Protection API, protects browser passwords, saved
  creds, etc. Master keys can be decrypted with the user's password or the DC
  backup key; a rich source of secondary credentials.

### Where credentials live on a machine (and how they get stolen)

- **LSASS process memory** — the Local Security Authority holds hashes, Kerberos
  tickets, and sometimes plaintext (WDigest on old systems) for logged-on users.
  **Mimikatz** reads LSASS. This is the classic "dump creds from a box you got
  admin on" step.
- **SAM + SYSTEM hives** — local account hashes.
- **`NTDS.dit` + SYSTEM** — the entire domain's hashes (only on DCs, or via
  DCSync remotely).
- **Credential caches / tickets on disk** — `.kirbi` (Rubeus) / `.ccache`
  (impacket) files.

### The three "pass-the-X" primitives

- **Pass-the-Hash (PtH)** — authenticate with an NT hash instead of a password
  (works because NTLM and RC4-Kerberos use the hash as the secret).
- **Pass-the-Ticket (PtT)** — inject a stolen/forged TGT or TGS into your
  session and use it.
- **Overpass-the-Hash (Pass-the-Key)** — use an NT/AES hash to request a real
  TGT from the KDC (turning a hash into a full Kerberos logon).

> **In this lab:** you will crack service-account hashes (Kerberoast/AS-REP),
> dump domain hashes with DCSync, and use the Administrator NT hash with
> Pass-the-Hash to read the final flag.

---

## 5. Enumeration: seeing the domain like an attacker

You cannot attack what you cannot see. Enumeration is the phase where you turn a
single foothold credential into a map of the whole domain. Almost everything
here is LDAP queries plus a few RPC/SMB calls.

**What you are hunting for:**

- All users, computers, and groups (and who is in privileged groups).
- Accounts with **SPNs** (Kerberoast targets) and accounts with **pre-auth
  disabled** (AS-REP targets).
- **Dangerous ACLs** — who has `GenericAll`/`WriteDacl`/etc. over whom.
- **Delegation** settings (unconstrained/constrained/RBCD).
- **Local admin rights** — which users are admin on which machines (the key to
  lateral movement).
- **Sessions** — which privileged users are currently logged onto which
  machines (so you know where to steal their tokens).
- Stale/weak config: passwords in description fields, `LAPS`, GPO abuses,
  certificate templates.

### BloodHound — the tool that changed AD attacking

**BloodHound** collects all of the above (via a "collector" like SharpHound or
the Python ingestor `bloodhound-python`) and loads it into a **graph database**.
It then answers questions like *"show me the shortest path from the account I
control to Domain Admin."* It models the domain as nodes (users, computers,
groups) and **edges** (relationships): `MemberOf`, `AdminTo`, `HasSession`,
`GenericAll`, `WriteDacl`, `CanRDP`, `AllowedToDelegate`, etc.

The mental shift BloodHound teaches: **AD compromise is graph traversal.** Each
edge is a technique that turns "control of A" into "control of B". Your job is
to find a chain of edges from where you are to where you want to be. The attacks
in section 6 are simply the individual edges.

> **In this lab:** run `bloodhound-python -d vuln.local -u helpdesk -p ... -c All`
> and you should see the path: `helpdesk` → (kerberoast) → `svc_mssql`
> → `GenericAll` → `IT Admins` → `DCSync` → domain compromise.

---

## 6. Attack technique catalog

Each technique below follows the same shape: **the idea**, **why it works**,
**how you do it**, and **how to detect/fix it**. These are the "edges" in the
graph.

### 6.1 AS-REP Roasting

**Idea.** Recover a user's password by cracking their AS-REP offline, without
needing any credentials at all (if you have the username list) — but only for
accounts that have **Kerberos pre-authentication disabled**.

**Why it works.** Normally the KDC refuses to issue an AS-REP unless you first
prove you know the password (pre-auth). If an admin sets *"Do not require
Kerberos preauthentication"* (userAccountControl flag `DONT_REQ_PREAUTH`,
`0x400000`), the KDC will hand out the AS-REP to anyone. Part of that AS-REP is
encrypted with the account's key, so it is a crackable oracle.

**How.**
```
GetNPUsers.py vuln.local/ -usersfile users.txt -no-pass -format hashcat -dc-ip <DC>
hashcat -m 18200 asrep.hash rockyou.txt
```

**Detect/fix.** Audit for accounts with `DONT_REQ_PREAUTH`; remove the flag
(it is almost never legitimately needed). Detect via event **4768** with
pre-auth type 0. Give any account that must keep it a very long random password.

> **In this lab:** `svc_backup` has pre-auth disabled; it cracks to `Backup2023`.

### 6.2 Kerberoasting

**Idea.** Recover a **service account's** password by requesting a service
ticket for its SPN and cracking that ticket offline.

**Why it works.** Any authenticated principal may request a TGS for any SPN
(that is normal Kerberos). The TGS is encrypted with the service account's key.
Service accounts frequently have (a) elevated privileges and (b) old, weak,
human-chosen passwords that never expire. Requesting RC4 (etype 23) tickets
makes cracking faster.

**How.**
```
GetUserSPNs.py vuln.local/helpdesk:Password -dc-ip <DC> -request -outputfile kerb.hash
hashcat -m 13100 kerb.hash rockyou.txt      # 13100 = RC4 TGS; 19600/19700 = AES
```

**Detect/fix.** Prefer **gMSA** (Group Managed Service Accounts) or 25+ char
random passwords; enforce AES; alert on bursts of event **4769** with RC4
encryption from unusual hosts. Consider "honey" SPN accounts as tripwires.

> **In this lab:** `svc_mssql` has an SPN and cracks to `Summer2024`.

### 6.3 Abusing Active Directory ACLs (DACL attacks)

**Idea.** Every AD object has a **DACL** (Discretionary Access Control List): a
list of **ACEs** (Access Control Entries) saying which principals may do what.
If you control a principal that holds a powerful ACE over another object, you can
take that object over. This is the richest source of escalation paths.

**Key abusable rights and what each buys you:**

| Right (ACE) | What you can do with it |
|---|---|
| `GenericAll` | Full control. Do anything below. |
| `GenericWrite` | Write most attributes (e.g. set an SPN → then Kerberoast; set `logonScript`; set RBCD). |
| `WriteDacl` | Rewrite the object's DACL → grant yourself `GenericAll`. |
| `WriteOwner` | Make yourself the owner → then rewrite the DACL. |
| `ForceChangePassword` | Reset the target user's password without knowing the old one. |
| `AddMember` (write `member`) | Add anyone to a group. |
| `AllowedToAct` (write `msDS-AllowedToActOnBehalfOfOtherIdentity`) | Configure **RBCD** and impersonate users to the target computer. |
| `DS-Replication-Get-Changes[-All]` | **DCSync** the domain (see 6.4). |

**Why it works.** These rights exist for legitimate delegated administration.
Misconfiguration (granting them too broadly, or to the wrong principal) turns
them into escalation. Nested groups make it worse: you often inherit a dangerous
ACE through several layers of group membership without realizing.

**How (example: GenericAll over a group → add yourself).**
```
# Using owned principal svc_mssql, add it to a privileged group:
net rpc group addmem "IT Admins" "svc_mssql" -U 'vuln.local/svc_mssql%Summer2024' -S <DC>
# Or with Windows RSAT:
Add-ADGroupMember -Identity "IT Admins" -Members svc_mssql
# ForceChangePassword example:
net rpc password "victim" "NewPass123!" -U 'vuln.local/attacker%pass' -S <DC>
# Grant yourself rights with dacledit (impacket) when you have WriteDacl:
dacledit.py -action write -rights FullControl -principal me -target-dn "<DN>" vuln.local/me:pass
```

**Detect/fix.** Regularly audit ACLs on privileged objects (`Get-Acl`, `dsacls`,
BloodHound). Protect privileged groups with **AdminSDHolder/SDProp**. Remove
excessive ACEs. Watch event **4728/4756** (member added to security-enabled
group) and **5136** (directory object modified).

> **In this lab:** `svc_mssql` has `GenericAll` over the `IT Admins` group. You
> add yourself to that group — a textbook DACL abuse edge.

### 6.4 DCSync

**Idea.** Ask a Domain Controller to hand you password hashes by *pretending to
be a DC performing replication.* Yields any account's hash, including `krbtgt`
and `Administrator` — i.e. full domain compromise.

**Why it works.** DCs replicate directory changes to each other using the
**Directory Replication Service (DRSUAPI)** protocol, specifically the
`DRSGetNCChanges` call. Access is gated by two extended rights on the domain
object: **`DS-Replication-Get-Changes`** and **`DS-Replication-Get-Changes-All`**
(plus `-In-Filtered-Set`). If a non-DC principal is granted these (misconfig, or
because you added yourself to a group that has them), you can invoke replication
and receive secrets — no need to log into the DC or touch `NTDS.dit` on disk.

**How.**
```
secretsdump.py 'vuln.local/svc_mssql:Summer2024'@<DC> -just-dc-user krbtgt
secretsdump.py 'vuln.local/svc_mssql:Summer2024'@<DC> -just-dc-user Administrator
# then Pass-the-Hash as Administrator:
netexec smb <DC> -u Administrator -H <NThash>
```

**Detect/fix.** Only DCs (and intended sync accounts) should hold replication
rights — audit and remove others. Detect via event **4662** where the accessed
object is the domain head and the property GUID is a replication right, coming
from a non-DC. This is one of the highest-signal detections in AD.

> **In this lab:** the `IT Admins` group was granted the replication rights, so
> once you are a member you can DCSync `krbtgt`/`Administrator`.

### 6.5 Kerberos delegation abuse (concept overview)

Delegation lets a service act *on behalf of* a user (e.g. a web server accessing
a database as the visiting user). Three flavors, all abusable:

- **Unconstrained delegation.** A computer configured for this stores the TGTs
  of every user who authenticates to it. Compromise that box, harvest TGTs
  (including, if you can coerce it, a DC's TGT). Extremely dangerous.
- **Constrained delegation (S4U2Self/S4U2Proxy).** An account may request
  tickets to a specific service *as any user*. If you control such an account,
  you can impersonate e.g. Administrator to that service.
- **Resource-Based Constrained Delegation (RBCD).** The *target* resource lists
  who may delegate to it, in `msDS-AllowedToActOnBehalfOfOtherIdentity`. If you
  can write that attribute on a computer (via `GenericWrite`/`GenericAll`), you
  add a computer account you control and then impersonate any user to that
  machine — a very common modern escalation.

These are not planted in this lab, but they are frequent interview topics and
BloodHound edges (`AllowedToDelegate`, `AllowedToAct`). Know the names and the
one-line "why".

---

## 7. Lateral movement and code execution

Once you have credentials (a password, an NT hash, or a ticket) for an account
that is **local admin** on a machine, you can execute code on that machine and
move sideways. The building blocks:

- **SMB + admin shares (`C$`, `ADMIN$`)** — remote file access as admin.
- **Service creation / scheduled tasks / WMI** — mechanisms to run a command
  remotely.

Common execution tools (all in impacket or similar), and the mechanism each uses:

| Tool | Mechanism | Notes |
|---|---|---|
| `psexec.py` | Creates a Windows **service** that runs your payload | Loud, drops a binary, very reliable. |
| `smbexec.py` | Service that runs commands via `cmd` | Slightly stealthier than psexec. |
| `wmiexec.py` | **WMI** (`Win32_Process`) | No binary dropped; semi-interactive. |
| `atexec.py` | **Scheduled task** | Runs a single command. |
| `evil-winrm` | **WinRM** (PowerShell remoting, 5985/5986) | Clean interactive shell if you have WinRM rights. |

All of these accept `-hashes` for **Pass-the-Hash** or a ticket for
**Pass-the-Ticket** (`-k -no-pass` in impacket after setting `KRB5CCNAME`).

**The lateral-movement loop** (this is the actual day-to-day of an AD attack):

1. Land on a machine as admin.
2. Dump credentials from LSASS / SAM (Mimikatz, or `secretsdump.py` locally).
3. Among the dumped creds, find one that is admin on *another* machine (this is
   what BloodHound's `AdminTo`/`HasSession` edges tell you).
4. Move there, repeat, until you reach a box where a Domain Admin is logged in —
   steal their token/ticket — then you own the domain.

**Token/session stealing.** If a privileged user has a session on a box you
control, you can impersonate their token (Mimikatz, incognito) or steal their
Kerberos tickets from LSASS and Pass-the-Ticket. This is why "where are the
admins logged in?" is such a valuable enumeration question.

---

## 8. Persistence and domain dominance

After reaching Domain Admin, attackers establish persistence so they keep access
even if the compromised account's password is reset. These are also the
"prove total control" techniques interviewers ask about.

- **Golden Ticket.** With the **`krbtgt` hash**, forge a TGT for any user
  (including a non-existent one) with any group memberships, valid for as long
  as you like. Because the TGT is encrypted/signed with `krbtgt`, the KDC trusts
  it. The only true fix is resetting `krbtgt` **twice** (it keeps the current
  and previous key). Tools: `ticketer.py` (impacket), Mimikatz, Rubeus.
- **Silver Ticket.** With a **service account's** hash, forge a TGS for that one
  service directly (skipping the KDC). Stealthier (no DC interaction) but scoped
  to one service on one host.
- **Diamond / Sapphire Tickets.** Modern variants that forge tickets while
  looking more like legitimate KDC-issued ones (harder to detect than classic
  golden tickets).
- **DCSync as persistence.** Grant a low-key account replication rights so you
  can re-dump hashes any time (the same misconfig this lab plants).
- **AdminSDHolder abuse.** Write an ACE onto the `AdminSDHolder` object; SDProp
  propagates it to all protected groups every hour, re-granting your access even
  after cleanup.
- **DСShadow.** Register a rogue DC and push malicious directory changes via
  replication.
- **Skeleton Key, custom SSPs, malicious GPOs** — other classic dominance
  tricks worth recognizing by name.

**The `krbtgt` account is the heart of Kerberos.** If you remember one thing:
control of `krbtgt`'s hash = ability to mint tickets = durable domain control.

---

## 9. Active Directory Certificate Services (ADCS)

ADCS is Microsoft's PKI (Public Key Infrastructure): it issues **certificates**,
which can be used for encryption *and* for **authentication** (you can log into
AD with a certificate instead of a password, via PKINIT Kerberos). In 2021 the
"Certified Pre-Owned" research (SpecterOps) showed that misconfigured ADCS is a
huge escalation surface, catalogued as **ESC1–ESC16+**.

**Core concepts:**

- **CA (Certification Authority)** — the server that issues certs. An
  *Enterprise CA* is integrated with AD.
- **Certificate template** — a policy object defining who may enroll and what
  the resulting cert can do/contain. Misconfigured templates are the problem.
- **EKU (Extended Key Usage)** — what a cert may be used for. **Client
  Authentication**, **PKINIT**, or **Any Purpose** EKUs let a cert authenticate
  as a user.
- **SAN (Subject Alternative Name)** — an identity baked into the cert. If a
  requester can choose the SAN, they can choose *who the cert authenticates as.*

**The escalations you should know:**

- **ESC1** — a template allows a low-priv user to enroll, has a client-auth EKU,
  and sets **`ENROLLEE_SUPPLIES_SUBJECT`** (requester picks the SAN), with no
  manager approval. Result: request a cert *as Administrator* and log in as them.
  **(This is the one planted in the lab.)**
- **ESC2** — template has the **Any Purpose** (or no) EKU — usable for anything.
- **ESC3** — an **Enrollment Agent** certificate lets you enroll *on behalf of*
  others.
- **ESC4** — you have **write access to the template object** itself (a DACL
  problem) → reconfigure it into ESC1.
- **ESC6** — the CA has the `EDITF_ATTRIBUTESUBJECTALTNAME2` flag set, so SAN can
  be supplied on *any* template.
- **ESC7** — you have dangerous rights on the **CA** (e.g. ManageCA/ManageCertificates).
- **ESC8** — **NTLM relay to the CA's web enrollment (HTTP)** endpoint: coerce a
  machine (e.g. a DC) to authenticate, relay it to the CA, get a cert for that
  machine → then compromise it. A very common real-world path.
- **ESC9/ESC10** — weak certificate mappings / `no security extension`.

**How ESC1 is abused (matches the lab):**
```
certipy-ad find -u helpdesk@vuln.local -p '...' -dc-ip <DC> -vulnerable -stdout
certipy-ad req  -u helpdesk@vuln.local -p '...' -ca VULN-Root-CA \
               -template VulnUserESC1 -upn Administrator@vuln.local
certipy-ad auth -pfx administrator.pfx -dc-ip <DC>   # -> Administrator TGT / NT hash
```

**Detect/fix.** Enumerate your own templates with `certipy find -vulnerable`.
Remove `ENROLLEE_SUPPLIES_SUBJECT` where not needed, require manager approval,
restrict enrollment, disable NTLM to the CA and enable EPA, and apply the strong
certificate-mapping enforcement (KB5014754). Monitor issued certs whose SAN
differs from the requester.

> **In this lab:** `srv01` hosts the Enterprise CA and publishes the vulnerable
> `VulnUserESC1` template. See `roles/vuln_adcs_esc1/` for exactly which
> attributes make it vulnerable, spelled out in PowerShell.

---

## 10. Trusts and multi-domain attacks

A **trust** lets users in one domain/forest access resources in another. Trusts
have a **direction** (A trusts B) and can be **transitive** or not.

- **Parent-child trust** (within a forest) — automatically two-way and
  transitive. Because they share the forest, compromising a child domain can
  often be escalated to the forest root using **SID History** and the
  **inter-realm trust key**.
- **Forest trust** — between two forests; more of a security boundary but still
  abusable, especially if **SID filtering** is not enforced.

**Key cross-domain techniques (recognize these):**

- **SID History injection** — add the SID of a privileged group from the target
  domain into your ticket's `SIDHistory`, so you are treated as privileged
  there. Used in inter-realm Golden Tickets to jump child → forest root.
- **Trust key abuse** — the shared key between two trusting domains can be used
  to forge inter-realm TGTs.
- **Foreign group membership / ACLs** — principals from one domain granted rights
  in another.

Remember the headline rule from section 2: **the forest is the security
boundary, not the domain.** Cross-domain trust attacks are why.

---

## 11. Detection and defense

Understanding defense is half of interview readiness — and it makes you a better
attacker because you learn what is noisy. Grouped by theme.

### High-value Windows Security event IDs

| Event | Meaning / what it can catch |
|---|---|
| 4624 / 4625 | Successful / failed logon (types matter: 3=network, 10=RDP). |
| 4768 | Kerberos **TGT** requested (AS-REP roasting: pre-auth type 0). |
| 4769 | Kerberos **service ticket** requested (Kerberoasting: RC4 etype 0x17 bursts). |
| 4662 | Operation on an AD object (**DCSync**: replication GUID from non-DC). |
| 4728 / 4756 | Member added to a (global/universal) security-enabled group. |
| 5136 | A directory object was modified (ACL/attribute changes). |
| 4738 / 4720 / 4726 | User account changed / created / deleted. |
| 4741 | Computer account created (RBCD / machine-account quota abuse). |
| 1102 | Security log cleared (attacker covering tracks). |
| 4698 | Scheduled task created (lateral movement). |

### Architectural defenses

- **Tiering / the "tier model".** Separate admin credentials into Tier 0 (DCs,
  domain admins), Tier 1 (servers), Tier 2 (workstations). A Tier 0 credential
  must never log into a Tier 2 box, so it cannot be stolen from a workstation.
  This single idea kills most lateral-movement-to-DA paths.
- **Protected Users group** — members get no NTLM, no RC4, no delegation, no
  long-lived cached creds. Great for admins.
- **LAPS** (Local Administrator Password Solution) — randomizes and rotates the
  local admin password on every machine, so one cracked local admin hash does
  not open every box.
- **gMSA** — managed service accounts with 120-char auto-rotated passwords; kills
  Kerberoasting for those accounts (but note: whoever has `ReadGMSAPassword`
  rights can retrieve the password, so watch that ACL).
- **Credential Guard** — uses virtualization to isolate LSASS secrets, blocking
  Mimikatz-style dumping.
- **Disable NTLM** where possible; enforce **AES** for Kerberos; enable **SMB
  signing** and **LDAP channel binding/signing** to stop relay.
- **Attack-surface hygiene** — no pre-auth-disabled accounts, no unconstrained
  delegation, least-privilege ACLs, audited certificate templates, and regular
  BloodHound runs *by the defenders* to find paths before attackers do.
- **`krbtgt` rotation** — reset it twice, periodically, to invalidate any
  unknown golden tickets.

### Detection tooling

- **BloodHound** (defensive use) — find and cut attack paths proactively.
- **PingCastle / Purple Knight** — AD security posture scoring.
- **Microsoft Defender for Identity (MDI)**, SIEM correlation of the events
  above, and canary/honeytoken accounts (a fake Kerberoastable admin that pages
  you the instant anyone requests its ticket).

---

## 12. Tooling reference

Grouped by purpose. You do not need all of them, but you should recognize each.

**Enumeration / mapping**
- **BloodHound** + **SharpHound** (C# collector) / **bloodhound-python** (remote
  collector) — the attack-path graph.
- **PowerView** (PowerShell) — classic domain enumeration from a Windows box.
- **ldapsearch**, **windapsearch**, **ldapdomaindump** — raw LDAP queries.
- **netexec (nxc)** / **CrackMapExec** — swiss-army knife: spray creds, list
  shares/users, check admin access across many hosts at once.
- **kerbrute** — fast username enumeration and password spraying via Kerberos.
- **enum4linux-ng**, **smbclient**, **rpcclient** — SMB/RPC enumeration.

**Kerberos / credential attacks**
- **impacket** — the Python toolkit that does almost everything:
  `GetUserSPNs.py` (Kerberoast), `GetNPUsers.py` (AS-REP), `secretsdump.py`
  (DCSync / local dumps), `ticketer.py` (golden/silver), `getST.py`
  (delegation), `dacledit.py`/`owneredit.py` (ACL edits), the `*exec.py` shells.
- **Rubeus** (C#, on Windows) — request/roast/forge/renew tickets, PtT, S4U.
- **Mimikatz** — dump LSASS, PtH/PtT, DCSync (`lsadump::dcsync`), golden tickets.
- **hashcat** / **John the Ripper** — offline cracking. Key hashcat modes:
  `13100` (Kerberoast RC4), `19600/19700` (Kerberoast AES), `18200` (AS-REP),
  `1000` (NTLM), `5600` (NetNTLMv2).

**ADCS**
- **Certipy** (Python) / **Certify** + **ForgeCert** (C#) — find and abuse
  vulnerable templates (ESC1–ESC16).

**Relay / coercion**
- **Responder** — poison LLMNR/NBT-NS/mDNS to capture NetNTLM hashes.
- **ntlmrelayx.py** (impacket) — relay captured NTLM auth to LDAP/SMB/HTTP(CA).
- **PetitPotam / Coercer / PrinterBug (SpoolSample)** — force a machine (often a
  DC) to authenticate to you, feeding a relay (e.g. ESC8).

**Shells / access**
- **evil-winrm** (WinRM), impacket `*exec.py`, **RDP**.

**A note on wordlists.** `rockyou.txt` (the leaked RockYou passwords) is the
default cracking list; rule files like `best64.rule` mutate it. The lab's weak
passwords are chosen to fall to rockyou quickly.

---

## 13. Glossary

- **AD** — Active Directory, Microsoft's directory/identity service.
- **DC** — Domain Controller, the server running AD.
- **KDC** — Key Distribution Center, the Kerberos service on the DC (AS + TGS).
- **NTDS.dit** — the DC's database file holding all accounts and hashes.
- **SAM** — local account database on a single Windows machine.
- **LSASS** — the process that holds logged-on users' secrets in memory.
- **NT hash** — MD4 of the (UTF-16LE) password; the credential NTLM/RC4 use.
- **TGT** — Ticket-Granting Ticket; your "logged in" token, sealed with krbtgt.
- **TGS** — service ticket; proof you may use one service.
- **SPN** — Service Principal Name; the unique name of a service for Kerberos.
- **PAC** — Privilege Attribute Certificate; group memberships inside a ticket.
- **krbtgt** — the account whose key protects all tickets; forging it = golden ticket.
- **PKINIT** — Kerberos authentication using a certificate instead of a password.
- **LDAP** — protocol used to query/modify the AD database.
- **DACL / ACE** — the permission list on an object / one entry in it.
- **SID** — Security Identifier; the unique ID of a principal.
- **RID** — Relative Identifier; the tail of a SID (e.g. 500 = Administrator).
- **UPN** — User Principal Name, e.g. `alice@vuln.local`.
- **OU** — Organizational Unit; a container for management/GPO/delegation.
- **GPO** — Group Policy Object; pushes settings/scripts to machines and users.
- **gMSA** — Group Managed Service Account; auto-rotating service account.
- **LAPS** — Local Administrator Password Solution; rotates local admin passwords.
- **RBCD** — Resource-Based Constrained Delegation.
- **DCSync** — pulling hashes by impersonating a replicating DC.
- **PtH / PtT** — Pass-the-Hash / Pass-the-Ticket.
- **ADCS** — AD Certificate Services (the PKI); ESCx are its misconfigurations.
- **PtH/relay/coercion** — see section 12.

---

## 14. How this maps to the lab + a study plan

### The lab's chain, mapped to this guide

```
Stage 0  Foothold          creds left on the pivot          (§5 enumeration begins)
Stage 1b AS-REP roast      svc_backup, no pre-auth          (§6.1)
Stage 1  Kerberoast        svc_mssql SPN -> crack           (§3.2, §6.2)
Stage 2  ACL abuse         GenericAll on "IT Admins"        (§6.3)
Stage 3  DCSync            IT Admins holds repl. rights      (§6.4) -> §4 PtH -> domain
Bonus    ADCS ESC1         VulnUserESC1 template            (§9)
```

Every planted weakness in this repo is one of the "edges" in section 6/9. The
repo's `docs/attack-chains.md` gives the concrete commands; this guide gives the
theory behind them.

### A concept-first study plan

1. **Read sections 1–4 until the Kerberos dance is intuitive.** If you can
   explain, from memory, why Kerberoasting and AS-REP roasting are just
   "something on the wire is encrypted with a weak key," you have the core.
2. **Build the lab** (`make all`) and run BloodHound from the `helpdesk`
   foothold. Find the path to Domain Admin *before* reading the walkthrough.
3. **Do each stage cold**, peeking at `docs/walkthrough.md` only when stuck.
   After each success, re-read the matching section here and the "Detect/fix"
   note, then say the defense out loud.
4. **`make reset-soft`** and repeat until you can run the whole chain in one
   sitting without notes.
5. **Stretch goals not planted here** (read the theory, then try them on other
   platforms like HTB machines): RBCD, constrained/unconstrained delegation,
   NTLM relay + ESC8, and a cross-domain SID-history escalation.

### Interview-ready one-liners to be able to say

- *Kerberoasting:* "Any authenticated user can request a service ticket for any
  SPN; the ticket is encrypted with the service account's key, so I crack it
  offline with no lockout risk. Fix: gMSA or long random passwords and AES."
- *DCSync:* "Replication rights on the domain let me impersonate a DC and pull
  any hash including krbtgt. Only DCs should have those rights; detect on event
  4662 with a replication GUID from a non-DC."
- *ESC1:* "The template lets a low-priv user supply the SAN and has a client-auth
  EKU, so I request a cert as a Domain Admin and authenticate with it. Fix:
  remove enrollee-supplied-subject, require approval, restrict enrollment."
- *The golden rule:* "Control of the krbtgt hash means I can forge any ticket,
  so the whole domain's trust collapses to that one secret."

---

### Further reading (canonical sources)

- Microsoft's Kerberos and AD documentation (protocol-level truth).
- SpecterOps: the BloodHound docs and the "Certified Pre-Owned" ADCS whitepaper.
- The HackTricks and The Hacker Recipes sites (technique cheat-sheets — use them
  after you understand the theory here, not instead of it).
- Harmj0y's blog posts on Kerberos, delegation, and ACLs.

Remember: tools change, protocols don't. Master sections 3 and 4 and every tool
in section 12 becomes just a convenient front-end to ideas you already own.
