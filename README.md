# learn-ansible-vulnerable-lab-env

A small, fully-automated **vulnerable Active Directory lab**, defined entirely
as code and deployed to **AWS**. Terraform builds the machines, Ansible turns
them into a Windows domain with deliberately-planted attack chains and a flag at
every stage. It exists to practice AD attack paths (Kerberoast, ACL abuse,
DCSync, ADCS ESC1) on infrastructure you own.

Built for personal, isolated study and interview prep (HackTheBox / OSCP style),
and specifically for machines that cannot run x86-64 Windows VMs locally, such as
Apple Silicon Macs.

---

## Contents

- [Safety first](#-safety-first--read-this)
- [How it works: two jobs, two tools](#how-it-works-two-jobs-two-tools)
- [What you get](#what-you-get)
- [Prerequisites](#prerequisites)
- [Step-by-step quick start](#step-by-step-quick-start)
- [One-command lifecycle (Make targets)](#one-command-lifecycle-make-targets)
- [Repository layout](#repository-layout)
- [Customising the lab](#customising-the-lab)
- [Resetting](#resetting)
- [Cost control](#cost-control)
- [Learning resources in this repo](#learning-resources-in-this-repo)
- [License](#license)

---

## ⚠️ Safety first — read this

This project **intentionally deploys insecure configurations**: weak passwords,
Kerberoastable service accounts, a group with DCSync rights, and a misconfigured
certificate template. Treat it like live malware for a network.

- **Isolated by design.** All hosts live in a dedicated AWS VPC on a private
  `10.10.10.0/24` subnet. Management ports (RDP/WinRM/SSH) are opened **only to
  your own public IP** by the security group. Never widen that to `0.0.0.0/0`.
- **Never** reuse these credentials, hostnames, or templates anywhere real.
- Use it only on an AWS account you control and are authorised to use, and
  **tear it down when you're done** (`make tf-destroy`).

---

## How it works: two jobs, two tools

Building infrastructure and configuring it are two different jobs, done by two
different tools:

1. **Provision (Terraform)** — create the four VMs, the network, and the
   firewall, and switch on WinRM so Ansible can connect. Lives in `terraform/`.
2. **Configure (Ansible)** — promote the domain, create the users and groups,
   plant the vulnerabilities, install the CA, and drop the flags. Lives in
   `roles/`, `playbooks/`, and `site.yml`.

Terraform records what it created in a state file; Ansible is idempotent. Both
phases are safe to re-run. This is the same pattern used in real environments,
which is part of what makes the lab good practice.

---

## What you get

| Host    | Private IP    | Role                                             |
|---------|---------------|--------------------------------------------------|
| `dc01`  | 10.10.10.10   | Domain Controller + DNS for `vuln.local`         |
| `srv01` | 10.10.10.20   | Domain member: **ADCS** Enterprise CA + SMB loot |
| `ws01`  | 10.10.10.30   | Domain-joined workstation (optional)             |
| `pivot` | 10.10.10.5    | Linux attacker box (your foothold + tooling)     |

**Three attack chains, six flags:**

1. **Chain 1 — Kerberoast → ACL abuse → DCSync** (the main event)
   `foothold` → `kerberoast` → `acl_abuse` → `dcsync`
2. **Chain 1b — AS-REP roasting** (a parallel warm-up into Chain 1)
   `asrep`
3. **Bonus — ADCS ESC1** (enrollee-supplied SAN → Domain Admin cert)
   `adcs_esc1`

Each flag lives behind an NTFS ACL or an identity you must first obtain, so a
flag proves you actually completed that step. The intended path is in
[`docs/walkthrough.md`](docs/walkthrough.md); the theory is in
[`docs/ad-security-guide.md`](docs/ad-security-guide.md).

---

## Prerequisites

On your Mac (the **control node**):

- An **AWS account** and IAM credentials that can create VPC/EC2 resources.
- **Terraform** ≥ 1.5, the **AWS CLI**, and **Ansible** (`ansible-core` ≥ 2.17).
- An SSH key pair (`~/.ssh/id_rsa` / `id_rsa.pub`).

```bash
brew install terraform awscli ansible
python3 -m pip install pywinrm            # lets Ansible speak WinRM to Windows
aws configure                             # store your AWS keys + region
make deps                                 # Ansible collections + Python deps
```

The Ansible control node can be macOS or Linux (never Windows). Nothing about
the lab runs locally on your Mac; the VMs live in AWS.

---

## Step-by-step quick start

Job 1 — provision the VMs with Terraform:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
#  edit terraform.tfvars:
#   - operator_cidr : your public IP + /32   (curl -s https://checkip.amazonaws.com)
#   - admin_password: must match inventory/group_vars/windows.yml
terraform init      # download providers (run once)
terraform plan      # preview what will be created (no changes)
terraform apply      # create the VMs; writes ../inventory/hosts.ini
cd ..
```

Wait ~5 minutes for the Windows hosts to finish first boot (rename + WinRM +
reboot). Then confirm connectivity:

```bash
cat inventory/hosts.ini                         # public IPs filled in by Terraform
ansible windows -m ansible.windows.win_ping     # expect: pong
ansible linux_pivot -m ansible.builtin.ping     # expect: pong
```

Job 2 — configure the lab with Ansible:

```bash
ansible-playbook site.yml
```

Then start attacking from the pivot:

```bash
ssh ubuntu@<pivot_public_ip>     # public IP from `terraform output`
cat ~/notes/creds.txt            # Stage 0 foothold + first flag
```

Full details and gotchas: [`docs/setup-cloud-aws.md`](docs/setup-cloud-aws.md).

---

## One-command lifecycle (Make targets)

```
make deps         Install Ansible collections + Python deps
make tf-init      Terraform: initialise / download providers (run once)
make tf-plan      Terraform: preview infrastructure changes
make tf-apply     Terraform: create the AWS VMs + generate inventory/hosts.ini
make all          Full build: tf-apply then Ansible deploy
make ping         WinRM + SSH connectivity check
make deploy       Ansible: build the domain, vulns, and flags
make check        Ansible dry-run (no changes)
make reset-soft   Re-plant AD content / vulns / flags (no VM rebuild)
make flags        Print every flag and what gates it (spoiler)
make lint         yamllint + ansible-lint
make tf-destroy   Tear down all AWS resources (stop paying)
```

---

## Repository layout

```
.
├── terraform/               # JOB 1: provision the AWS VMs + enable WinRM
│   ├── versions.tf          #   providers (aws, local) + region/tags
│   ├── variables.tf         #   inputs (region, your IP, sizes, password)
│   ├── main.tf              #   VPC, subnet, security group, EC2 instances
│   ├── outputs.tf           #   outputs + generates inventory/hosts.ini
│   └── templates/           #   Windows WinRM bootstrap + inventory template
├── site.yml                 # JOB 2: full Ansible build (imports the playbooks)
├── playbooks/               # 01-dc … 07-pivot, plus reset.yml
├── roles/                   # domain_controller, ad_content, vuln_*, adcs_ca, flags, …
├── inventory/               # THE inventory
│   ├── hosts.ini.example    #   shape of the generated inventory
│   └── group_vars/          #   all.yml (users/vulns/flags) + connection settings
├── requirements.yml         # Ansible collections (microsoft.ad, ansible.windows…)
├── requirements.txt         # Python deps for the control node
├── scripts/check-flags.sh   # spoiler map of flags → gates
├── Makefile                 # the lifecycle targets above
└── docs/                    # guide, walkthrough, attack-chains, architecture, setup, troubleshooting
```

There is a single `inventory/`. `terraform apply` generates
`inventory/hosts.ini` (gitignored) from the live public IPs; the committed
`inventory/hosts.ini.example` shows its shape.

---

## Customising the lab

Everything planted — users, passwords, groups, SPNs, the ACL misconfig, the
ESC1 template, and all flag values — is declared in
[`inventory/group_vars/all.yml`](inventory/group_vars/all.yml). Edit there and
re-run `make deploy` (or `make reset-soft`). The walkthrough reads the same
values, so the docs stay in sync with your changes.

Connection settings (WinRM/SSH, credentials) live in the other files under
`inventory/group_vars/`. If you change `admin_password`, change it in **both**
`terraform/terraform.tfvars` and `inventory/group_vars/windows.yml`.

---

## Resetting

```bash
make reset-soft            # fast: re-plant AD content, vulns, ESC1 template, flags
make tf-destroy && make all   # full: rebuild the VMs for a guaranteed-clean slate
```

Use `reset-soft` between practice runs. Use the full rebuild when you have
issued certificates or forged tickets you want gone.

---

## Cost control

These are real, billable EC2 instances (default: two `t3.large`, one
`t3.medium`, one `t3.small`). Ballpark a few US dollars per day while running,
near zero when destroyed.

- `make tf-destroy` when you finish for the day (cheapest).
- Or stop the instances to keep state (you still pay for EBS storage).
- Set `enable_ws01 = false` in `terraform.tfvars` to drop the workstation.
- Stopped instances get **new public IPs** on restart — re-run `make tf-apply`
  to regenerate `inventory/hosts.ini`.

---

## Learning resources in this repo

- [`docs/ad-security-guide.md`](docs/ad-security-guide.md) — in-depth,
  concept-first AD security primer. Start here for the theory.
- [`docs/ad-attack-map.svg`](docs/ad-attack-map.svg) — one-page visual of the
  Kerberos flow and the full attack chain.
- [`docs/walkthrough.md`](docs/walkthrough.md) — the intended path, step by
  step, with real commands.
- [`docs/attack-chains.md`](docs/attack-chains.md) — how each misconfiguration
  works, and how to detect and fix it.
- [`docs/setup-cloud-aws.md`](docs/setup-cloud-aws.md) — the full AWS setup,
  end to end.
- [`docs/architecture.md`](docs/architecture.md) — topology, tool choices, the
  Terraform→Ansible handoff, and cost.
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — WinRM, quotas, DNS,
  ADCS timing, and other gotchas.

Instructor / spoiler view of the flags: `make flags`.

---

## License

MIT — see [`LICENSE`](LICENSE). Provided for authorised, isolated lab use only.
