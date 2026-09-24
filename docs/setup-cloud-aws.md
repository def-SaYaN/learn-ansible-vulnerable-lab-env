# Running the lab on AWS (for Apple Silicon Macs, or anyone without an x86 host)

Apple Silicon (M1–M4) cannot run the x86-64 Windows Server VMs this lab needs
under VirtualBox. This guide builds the same lab in AWS instead: **Terraform**
creates the four VMs and turns on WinRM, then the **same Ansible** (`site.yml`)
configures the domain, the deliberate misconfigurations, and the flags.

Nothing about the attack lab changes. Only the "where do the VMs live and how
does Ansible reach them" layer is different. The private IPs are identical
(`10.10.10.0/24`), so the roles and the walkthrough work unchanged.

> Cost + safety: these are real, billable EC2 instances. Management ports are
> locked to your IP only, but this is still an intentionally-vulnerable
> environment — keep it isolated, and run `terraform destroy` (or stop the
> instances) when you are not using it. Ballpark cost while running is a few
> US dollars per day; near zero when destroyed.

## Architecture

```
                         AWS VPC 10.10.0.0/16
                    subnet 10.10.10.0/24 (lab)
   ┌───────────┬───────────┬───────────┬───────────┐
  dc01 .10   srv01 .20   ws01 .30    pivot .5
  Windows    Windows     Windows     Ubuntu
  DC+DNS     ADCS+SMB     workstation attacker box
   └── full mesh inside the security group ──┘
   management (RDP/WinRM/SSH) open ONLY to your public IP
```

Your Mac is the **control node**: it runs Terraform and Ansible over the
internet to the instances' public IPs. (For a more production-like setup you
would run Ansible from the pivot so WinRM stays private — noted at the end.)

## Prerequisites on your Mac

```bash
brew install ansible terraform awscli
python3 -m pip install pywinrm
ansible-galaxy collection install -r requirements.yml
ssh-keygen -t rsa -b 4096   # if you don't already have ~/.ssh/id_rsa.pub
aws configure               # set your AWS access key, secret, region
```

You need an AWS account and IAM credentials allowed to create VPC/EC2 resources.

## Step 1 — configure the build

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

- `operator_cidr` — your public IP as a `/32`. Get it with
  `curl -s https://checkip.amazonaws.com` then append `/32`.
- `admin_password` — the Windows Administrator password. **It must match**
  `lab_domain_admin_password` and `ansible_password` in
  `inventory/group_vars/windows.yml`. Change both together if you edit it.
- optionally set `enable_ws01 = false` to drop the workstation and save money.

## Step 2 — provision the VMs

```bash
terraform init
terraform plan      # review what will be created
terraform apply     # type yes
```

This creates the VPC, subnet, security group, key pair, and instances, and
writes `inventory/hosts.ini` with the live public IPs. Wait ~5 minutes:
each Windows host renames itself, sets the Administrator password, enables
WinRM, and reboots on first boot.

## Step 3 — verify connectivity

```bash
cd ..
cat inventory/hosts.ini      # confirm IPs were filled in
ansible -i inventory/hosts.ini windows -m ansible.windows.win_ping
ansible -i inventory/hosts.ini linux_pivot -m ansible.builtin.ping
```

`win_ping` returning `pong` means WinRM + credentials are good. If it times
out, the host is probably still finishing first-boot — wait and retry.

## Step 4 — build the lab

```bash
ansible-playbook -i inventory/hosts.ini site.yml
```

Same playbook as the local build. It promotes `dc01`, joins the members,
creates the users/groups, plants the misconfigurations, installs ADCS, and
drops the flags. Then attack it exactly as `docs/walkthrough.md` describes,
starting from the pivot:

```bash
ssh -i ~/.ssh/id_rsa ubuntu@<pivot_public_ip>
cat ~/notes/creds.txt
```

## Step 5 — stop the meter

```bash
# Full teardown (removes everything, cheapest):
cd terraform && terraform destroy

# Or just stop the instances to keep state (you still pay for storage):
aws ec2 stop-instances --instance-ids <ids...>
```

If you stop/start instead of destroy, the **public IPs change** on restart —
re-run `terraform apply` to regenerate `inventory/hosts.ini`.

## Notes, gotchas, and hardening

- **Why the admin password is in two places.** Terraform sets it on the box;
  Ansible uses it to log in. They are independent, so they must be kept equal.
- **user_data visibility.** The password is passed via EC2 user-data (fine for
  a throwaway lab). For anything longer-lived, fetch it from AWS Secrets
  Manager in the bootstrap script instead.
- **Run Ansible from the pivot (more realistic).** Instead of opening WinRM to
  the internet, copy the repo to the pivot and run `ansible-playbook` there, so
  Windows management traffic stays inside the VPC. Then only SSH to the pivot
  needs to be exposed.
- **DNS.** `common_win` points every host's DNS at `10.10.10.10` (the DC's
  private IP), which is why domain join works even though AWS hands out its own
  resolver by default.
- **Instance sizing.** The DC and member server default to `t3.large` (8 GB).
  Domain promotion is memory-hungry; smaller types may fail or crawl.
