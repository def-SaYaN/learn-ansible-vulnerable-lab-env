#!/usr/bin/env bash
# One-command reset. Default = HARD reset (destroy + rebuild).
# Pass --soft to only re-plant AD content/vulns/flags (much faster).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--soft" ]]; then
  echo "[*] Soft reset: re-planting AD content, vulns and flags..."
  ansible-playbook playbooks/reset.yml
  echo "[+] Soft reset complete."
else
  echo "[*] HARD reset: destroying and rebuilding every VM..."
  vagrant destroy -f
  vagrant up
  ansible-playbook site.yml
  echo "[+] Lab rebuilt clean."
fi
