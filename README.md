# learn-ansible-vulnerable-lab-env

A small, fully-automated **vulnerable Active Directory lab**, defined entirely
as code. Ansible builds a Windows domain with deliberately-planted attack
chains, a flag at every stage, and a one-command reset. It is meant for
practising AD attack paths (Kerberoast, ACL abuse, DCSync, ADCS ESC1) on
hardware you own.

Built for personal, offline study and interview prep (HackTheBox / OSCP style).

---

## ⚠️ Safety first — read this

This project **intentionally deploys insecure configurations**: weak passwords,
Kerberoastable service accounts, a domain user with DCSync rights, and a
misconfigured certificate template. Treat it like live malware for your network.

- **Isolated networks only.** Everything runs on a host-only network
  (`10.10.10.0/24`). Do **not** bridge these VMs to your LAN, a corporate
  network, or the internet.
- The only outbound path is the pivot's NAT interface, used solely to download
  the box and packages at build time. You can remove it once built.
- **Never** reuse these credentials, hostnames, or templates anywhere real.
- Use it only on infrastructure you own and are authorised to test.

---

## What you get

| Host    | IP            | Role                                             |
|---------|---------------|--------------------------------------------------|
| `dc01`  | 10.10.10.10   | Domain Controller + DNS for `vuln.local`         |
| `srv01` | 10.10.10.20   | Domain member: **ADCS** Enterprise CA + SMB loot |
| `ws01`  | 10.10.10.30   | Domain-joined workstation                        |
| `pivot` | 10.10.10.5    | Linux attacker box (your foothold + tooling)     |

**Three attack chains, six flags:**

1. **Chain 1 — Kerberoast → ACL abuse → DCSync** (the main event)
   `foothold` → `kerberoast` → `acl_abuse` → `dcsync`
2. **Chain 1b — AS-REP roasting** (a parallel warm-up into Chain 1)
   `asrep`
3. **Bonus — ADCS ESC1** (enrollee-supplied SAN → Domain Admin cert)
   `adcs_esc1`

Each flag lives behind an NTFS ACL or an identity you must first obtain, so a
flag is proof you actually completed that step. The full intended path is in
[`docs/walkthrough.md`](docs/walkthrough.md).

---

## Prerequisites (control node / your machine)

- A hypervisor: **VirtualBox** (default) or **libvirt/KVM**
- **Vagrant** ≥ 2.2
- **Ansible** (`ansible-core` ≥ 2.17) with WinRM support
- ~9 GB RAM free for the four VMs, ~40 GB disk

```bash
# one-time control-node setup
make deps           # pip deps + ansible-galaxy collections
```

## Quick start

```bash
make all            # boot the VMs, then provision the whole lab
# ...grab a coffee; the DC promote + member joins involve several reboots...

vagrant ssh pivot
cat ~/notes/creds.txt      # Stage 0 foothold + first flag
```

Then open [`docs/walkthrough.md`](docs/walkthrough.md) and work the chains.

Prefer to drive it by hand?

```bash
make up             # just boot the VMs
make deploy         # run site.yml (idempotent; safe to re-run)
make check          # dry-run, show what would change
make ping           # WinRM + SSH connectivity check
```

## One-command reset

```bash
make reset          # HARD: destroy + rebuild every VM (fully pristine)
make reset-soft     # FAST: re-plant AD content / vulns / flags, no rebuild
```

Use `reset-soft` between practice runs. Use `reset` when you have issued
certificates or forged tickets you want gone (see
[`docs/troubleshooting.md`](docs/troubleshooting.md)).

## Repository layout

```
.
├── Vagrantfile              # 4 VMs on an isolated host-only network
├── Makefile                 # up / deploy / reset / check / flags
├── site.yml                 # full build (imports the staged playbooks)
├── requirements.yml         # Ansible collections (microsoft.ad, ansible.windows…)
├── inventory/
│   ├── hosts.ini
│   └── group_vars/          # connection + the single source of truth (all.yml)
├── playbooks/               # 01-dc … 07-pivot, plus reset.yml
├── roles/                   # domain_controller, ad_content, vuln_*, adcs_ca, flags, …
├── scripts/                 # deploy.sh, reset.sh, check-flags.sh
└── docs/                    # walkthrough, architecture, attack-chains, troubleshooting
```

## Customising the lab

Everything planted — users, passwords, groups, SPNs, the ACL misconfig, the
ESC1 template, and all flag values — is declared in
[`inventory/group_vars/all.yml`](inventory/group_vars/all.yml). Edit there and
re-run `make deploy` (or `make reset-soft`). The walkthrough reads from the same
values, so the docs stay in sync with whatever you change.

## Instructor / spoiler view

```bash
make flags          # prints every flag and exactly what gates it
```

## Documentation

- [`docs/ad-attack-map.svg`](docs/ad-attack-map.svg) — one-page visual: the Kerberos flow and the full attack chain
- [`docs/ad-security-guide.md`](docs/ad-security-guide.md) — in-depth, concept-first AD security primer (start here to learn the theory)
- [`docs/walkthrough.md`](docs/walkthrough.md) — the intended path, step by step, with commands
- [`docs/attack-chains.md`](docs/attack-chains.md) — how each misconfig works and how to detect/fix it
- [`docs/architecture.md`](docs/architecture.md) — topology, providers, design decisions
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — WinRM, reboots, DNS, ADCS gotchas

## License

MIT — see [`LICENSE`](LICENSE). Provided for authorised, isolated lab use only.
