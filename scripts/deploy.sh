#!/usr/bin/env bash
# Bring the lab fully up: boot VMs, then provision with Ansible.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[*] Installing control-node dependencies..."
python3 -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml

echo "[*] Booting VMs with Vagrant..."
vagrant up

echo "[*] Provisioning the domain, vulnerabilities and flags..."
ansible-playbook site.yml

echo "[+] Lab is up. Read docs/walkthrough.md, then SSH to the pivot:"
echo "    vagrant ssh pivot   ->   cat ~/notes/creds.txt"
