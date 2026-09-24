# Architecture & design

## Two jobs, two tools

The lab is built in two clearly separated phases:

1. **Provision (Terraform)** — create the four VMs and the network they sit on,
   and enable WinRM so they can be managed. Code in `terraform/`.
2. **Configure (Ansible)** — promote the domain, create users/groups, plant the
   deliberate misconfigurations, install ADCS, and drop the flags. Code in
   `roles/`, `playbooks/`, and `site.yml`.

This mirrors real infrastructure work: one tool builds the machines, another
configures them. Terraform tracks what it built in a state file; Ansible is
idempotent, so both phases are safe to re-run.

## Topology (AWS)

```
                         AWS VPC 10.10.0.0/16
                    subnet 10.10.10.0/24 (lab)
   ┌───────────┬────────────┬───────────┬───────────┐
  dc01 .10   srv01 .20    ws01 .30    pivot .5
  Windows    Windows      Windows     Ubuntu
  DC + DNS   ADCS + SMB   workstation attacker box
   └──────── full mesh inside the security group ────────┘
   management ports (RDP/WinRM/SSH) open ONLY to your public IP
```

- **One forest, one domain:** `vuln.local` (NetBIOS `VULN`).
- `dc01` is the only Domain Controller and the DNS server for the zone. Every
  other host resolves through its private IP `10.10.10.10` (`common_win` sets
  this), which is how domain join works despite AWS handing out its own
  resolver by default.
- `srv01` hosts the Enterprise Root CA (`VULN-Root-CA`) and the SMB shares that
  hold the loot flags.
- `ws01` is a plain domain-joined workstation, present for realism and a second
  member to practice on. Set `enable_ws01 = false` to skip it and save money.
- `pivot` is the attacker workstation. It has internet access via the VPC's
  internet gateway so it can install offensive tooling at build time.
- Your Mac is the **control node**: it runs Terraform and Ansible over the
  internet to the instances' public IPs, which the security group restricts to
  your IP alone.

## Why these tool choices

- **Terraform** for provisioning: declarative, stateful, the standard for cloud
  infrastructure. The AWS provider creates the VPC, subnet, gateway, routing,
  security group, key pair, and EC2 instances.
- **Ansible** for configuration: the `microsoft.ad` collection handles the DC
  promote / domain join reboot dance idempotently; `ansible.windows` and
  `community.windows` cover features, services, and templating.
- **WinRM (NTLM over HTTP)** for the Ansible transport. NTLM gives
  message-level encryption, and the security group limits exposure to your IP.
  For a production-like setup you would run Ansible from the pivot so WinRM
  never leaves the VPC (see `docs/setup-cloud-aws.md`).
- **`dsacls`** for the ACL/DCSync grants because it maps 1:1 to what a defender
  audits and needs no extra modules.
- **ADSI (PowerShell)** for the ESC1 template because there is no first-class
  Ansible module for certificate templates; the script in
  `roles/vuln_adcs_esc1/templates/` is explicit about every vulnerable
  attribute.

## How Terraform enables remote access

In the cloud nothing pre-enables WinRM for you (unlike a Vagrant base box).
Terraform passes a first-boot PowerShell script to each Windows instance via
EC2 `user_data` (`terraform/templates/windows_userdata.ps1.tpl`). On first boot
it renames the host to its lab name, sets a known local Administrator password,
enables the WinRM service and listener, opens the firewall, and reboots once so
the rename takes effect. After that, Ansible can log in as `Administrator`.

## The Terraform → Ansible handoff

`terraform apply` finishes by writing `inventory/hosts.ini` (via a `local_file`
resource rendered from `terraform/templates/inventory.ini.tpl`) containing the
live public IPs. That generated file is the bridge: Ansible reads it as its
inventory. The private IPs are fixed (`10.10.10.10` etc.) so the domain-side
variables never change between rebuilds.

## Build order (and why)

`site.yml` imports the staged playbooks in a fixed order because each depends
on the previous:

1. `01` promote `dc01` (the forest must exist first)
2. `02` join members (need the DC + its DNS)
3. `03` create OUs/groups/users (the directory must exist)
4. `04` plant AD vulns (reference the users/groups from step 3)
5. `05` install ADCS + ESC1 on `srv01` (needs the domain)
6. `06` plant flags + shares (reference identities from steps 3–5)
7. `07` configure the pivot + Stage 0 foothold

Every role is idempotent, so `make deploy` can be re-run safely and
`make reset-soft` re-plants from the same code.

## Single source of truth

`inventory/group_vars/all.yml` defines all users, passwords, groups, SPNs, the
ACL misconfig, the ESC1 template, and the flag strings. Roles and the
walkthrough both read from it, so editing one file keeps code and docs aligned.
Connection details (WinRM/SSH, credentials) live in the other `group_vars`
files.

## Resource footprint & cost

| Host  | Default type | vCPU | RAM   |
|-------|--------------|------|-------|
| dc01  | t3.large     | 2    | 8 GB  |
| srv01 | t3.large     | 2    | 8 GB  |
| ws01  | t3.medium    | 2    | 4 GB  |
| pivot | t3.small     | 2    | 2 GB  |

These are billable while running. Ballpark a few US dollars per day running,
near zero when destroyed. `make tf-destroy` removes everything; stopping
instances keeps state but still incurs EBS storage cost. Drop `ws01`
(`enable_ws01 = false`) if you want to trim the bill.
