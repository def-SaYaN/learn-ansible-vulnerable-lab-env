#!/usr/bin/env bash
# Print every flag and the identity that gates it (SPOILER / instructor view).
set -euo pipefail
cd "$(dirname "$0")/.."
echo "=========================================================="
echo " VULN.LOCAL - flag map (SPOILER)"
echo "=========================================================="
python3 - <<'PY'
import re, pathlib
f = pathlib.Path("inventory/group_vars/all.yml").read_text()
block = f.split("lab_flags:")[1]
rows = re.findall(r'^\s{2}(\w+):\s*"([^"]+)"', block, re.M)
gate = {
  "foothold":  "pivot: ~/notes/creds.txt (any pivot user)",
  "asrep":     "SMB \\\\srv01\\backups$  (as svc_backup, after AS-REP roast+crack)",
  "kerberoast":"SMB \\\\srv01\\mssql_backups$ (as svc_mssql, after Kerberoast+crack)",
  "acl_abuse": "SMB \\\\srv01\\itadmin$ (member of 'IT Admins', via GenericAll abuse)",
  "dcsync":    "\\\\dc01\\C$\\Flags\\domain_pwned.txt (Domain Admin, after DCSync)",
  "adcs_esc1": "\\\\srv01\\C$\\Flags\\adcs_esc1.txt (Domain Admin, via ESC1 cert)",
}
for k,v in rows:
    print(f"\n[{k}]\n  flag : {v}\n  gate : {gate.get(k,'?')}")
PY
echo
echo "=========================================================="
echo " Full intended path: docs/walkthrough.md"
echo "=========================================================="
