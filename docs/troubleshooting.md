# Troubleshooting

## WinRM won't connect / `make ping` fails on Windows
- The VM may still be finishing first boot or a reboot. Wait, then retry.
- Confirm the box has WinRM on 5985: `vagrant winrm dc01 -c "hostname"` (if your
  Vagrant version supports it) or check `vagrant status`.
- The private-network NIC can come up after WinRM. Re-run `vagrant reload dc01`.
- Credentials are `vagrant`/`vagrant` until the DC promote sets the domain admin
  password (`lab_domain_admin_password`). After promotion, use the domain admin.

## DC promotion seems stuck
- Promotion reboots the box; `microsoft.ad.domain` waits and reconnects. The
  follow-up task retries LDAP for up to 10 minutes. If it exceeds that, the box
  is likely low on RAM — give `dc01` at least 2.5 GB.

## Members fail to join ("domain not found")
- DNS. Members must point at `10.10.10.10`. `roles/common_win` sets this, but if
  the member booted before the DC's DNS was ready, re-run
  `ansible-playbook playbooks/02-domain-join.yml`.

## `dsacls` task reports "changed" every run
- Expected/benign: the change detection keys off the success string. The grant
  itself is idempotent — re-applying the same ACE is a no-op in AD.

## ADCS: ESC1 template not visible to `certipy find`
- Template publication replicates asynchronously. The role pauses and retries,
  but if you built very fast, wait a minute and re-run
  `ansible-playbook playbooks/05-adcs.yml`.
- Confirm on `srv01`: `certutil -CATemplates | findstr VulnUserESC1`.

## Cracking is slow / no wordlist
- `hashcat -m 13100`/`-m 18200` with `rockyou.txt`. On Kali it is at
  `/usr/share/wordlists/rockyou.txt.gz` (gunzip it first). The planted passwords
  (`Summer2024`, `Backup2023`) are in rockyou-style lists.

## I abused something and now the lab is dirty
- `make reset-soft` re-plants AD content, vulns, the ESC1 template and flags
  (removes extra group members, resets passwords, rebuilds the template ACL).
- **Issued certificates and golden tickets survive a soft reset.** For a
  guaranteed-clean lab use `make reset` (full destroy + rebuild).

## Pivot tooling didn't install
- The pip step needs internet at build time via the pivot's NAT interface. If
  you built offline, `vagrant ssh pivot`, then
  `source /opt/offsec-venv/bin/activate && pip install impacket certipy-ad`.

## Disk / "no space left"
- `make destroy` removes the VMs and frees space. Windows boxes are large
  (~10 GB each); ensure ~40 GB free before `make all`.

## Everything is broken and I want a clean slate
```bash
make destroy && make all
```
