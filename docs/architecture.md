# Architecture & design

## Topology

```
                 host-only network 10.10.10.0/24  (isolated)
   ┌───────────────┬────────────────┬───────────────┬──────────────┐
   │               │                │               │              │
 dc01           srv01             ws01            pivot         (your host)
 .10            .20               .30             .5            runs Vagrant
 DC + DNS       member            workstation     Linux         + Ansible
 vuln.local     ADCS CA           domain-joined   attacker box
                SMB loot shares                   NAT for build only
```

- **One forest, one domain:** `vuln.local` (NetBIOS `VULN`).
- `dc01` is the only DC and the DNS server for the zone. Every other host
  resolves through it (`roles/common_win` sets this).
- `srv01` hosts the Enterprise Root CA (`VULN-Root-CA`) and the SMB shares that
  hold the Kerberoast/AS-REP/ACL loot flags.
- `ws01` is a plain domain-joined workstation, present so the domain looks
  realistic and to give a second member for lateral-movement practice.
- `pivot` is the attacker workstation. It keeps a NAT interface **only** so the
  box and offensive tooling can download at build time; nothing in the domain
  routes to it.

## Why these tool choices

- **Vagrant** for VM lifecycle: declarative, reproducible, provider-agnostic
  (VirtualBox by default, libvirt supported).
- **Ansible** for configuration: the `microsoft.ad` collection handles the
  DC promote / domain join reboot dance idempotently; `ansible.windows` and
  `community.windows` cover features, services, firewall and templating.
- **WinRM (NTLM over HTTP)** on the isolated network keeps the control path
  simple and reproducible. On any exposed network you would switch to HTTPS +
  CredSSP — see `inventory/group_vars/windows.yml`.
- **`dsacls`** for the ACL/DCSync grants because it maps 1:1 to what a defender
  audits, and is present on every DC with no extra modules.
- **ADSI** for the ESC1 template because there is no first-class Ansible module
  for certificate templates; the PowerShell in
  `roles/vuln_adcs_esc1/templates/` is explicit about every vulnerable attribute.

## Build order (and why)

`site.yml` imports the staged playbooks in a fixed order because each depends on
the previous:

1. `01` promote `dc01` (forest must exist first)
2. `02` join members (need the DC + its DNS)
3. `03` create OUs/groups/users (directory must exist)
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

## Providers

- **VirtualBox** (default): works out of the box with the referenced boxes.
- **libvirt/KVM**: install `vagrant-libvirt`; run with
  `VAGRANT_DEFAULT_PROVIDER=libvirt vagrant up`. The Vagrantfile already carries
  a `libvirt` provider block. You may need libvirt-compatible boxes.

## Resource footprint

| Host  | vCPU | RAM    |
|-------|------|--------|
| dc01  | 2    | 2.5 GB |
| srv01 | 2    | 2.5 GB |
| ws01  | 2    | 2.0 GB |
| pivot | 1    | 1.0 GB |

Drop `ws01` from `NODES` in the `Vagrantfile` and from `[domain_members]` in the
inventory if you are tight on RAM; nothing in the chains strictly requires it.
