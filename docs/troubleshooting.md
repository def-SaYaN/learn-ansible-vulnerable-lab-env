# Troubleshooting (AWS build)

## `terraform apply` fails: AMI not found in region
- The Windows AMI name filter must match your region. Change `aws_region` in
  `terraform/terraform.tfvars`, or adjust `windows_ami_pattern`. Check what's
  available: `aws ec2 describe-images --owners amazon --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" --query 'Images[].Name' --region <region>`.

## `terraform apply` fails: instance type / vCPU quota
- New AWS accounts have low On-Demand vCPU limits. `t3.large` x2 + `t3.medium`
  + `t3.small` may exceed them. Request a quota increase, or set
  `enable_ws01 = false` and use smaller types in `terraform.tfvars`.

## `make ping` / `win_ping` times out on the Windows hosts
- Most common cause: the host is still finishing first boot. The `user_data`
  script renames the host, enables WinRM, and reboots once; give it ~5 minutes
  after `terraform apply` completes, then retry.
- Confirm the security group allows your IP: `operator_cidr` must be your
  **current** public IP (`curl -s https://checkip.amazonaws.com`). If your IP
  changed, update it and re-run `terraform apply`.
- Confirm the password matches: `ansible_password` in
  `inventory/group_vars/windows.yml` must equal Terraform's `admin_password`.

## Public IPs changed after stop/start
- Auto-assigned public IPs change when an instance stops and starts. Re-run
  `terraform apply` to regenerate `inventory/hosts.ini` with the new addresses.

## DC promotion seems stuck
- Promotion reboots the box; `microsoft.ad.domain` waits and reconnects, and a
  follow-up task retries LDAP for ~10 minutes. If it exceeds that, the instance
  is likely too small; the DC wants `t3.large` (8 GB).

## Members fail to join ("domain not found")
- DNS. Members must resolve through the DC's private IP `10.10.10.10`.
  `common_win` sets this, but if a member booted before the DC's DNS was ready,
  re-run `ansible-playbook playbooks/02-domain-join.yml`.

## `dsacls` task reports "changed" every run
- Expected/benign: change detection keys off the success string. Re-applying
  the same ACE in AD is a no-op.

## ADCS: ESC1 template not visible to `certipy find`
- Template publication replicates asynchronously. The role pauses and retries;
  if you built very fast, wait a minute and re-run
  `ansible-playbook playbooks/05-adcs.yml`. Confirm on `srv01`:
  `certutil -CATemplates | findstr VulnUserESC1`.

## Cracking is slow / no wordlist
- Use `hashcat -m 13100` (Kerberoast) / `-m 18200` (AS-REP) with
  `rockyou.txt`. On Kali it's at `/usr/share/wordlists/rockyou.txt.gz`
  (gunzip first). The planted passwords are rockyou-crackable.

## I abused something and now the lab is dirty
- `make reset-soft` re-plants AD content, vulns, the ESC1 template and flags
  (removes extra group members, resets passwords, rebuilds the template).
- Issued certificates and forged tickets survive a soft reset. For a
  guaranteed-clean lab, tear down and rebuild: `make tf-destroy && make all`.

## Pivot tooling didn't install
- The pip step needs internet, which the pivot has via the VPC's internet
  gateway. If it failed, `ssh ubuntu@<pivot_public_ip>`, then
  `source /opt/offsec-venv/bin/activate && pip install impacket certipy-ad`.

## Stop paying
- `make tf-destroy` removes everything. Or stop (not terminate) the instances
  to keep state; you still pay for EBS storage while stopped.
