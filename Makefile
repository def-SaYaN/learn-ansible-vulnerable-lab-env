# ===========================================================================
#  learn-ansible-vulnerable-lab-env  --  Makefile
#  One-command lifecycle for the vulnerable AD lab.
# ===========================================================================
SHELL := /bin/bash
ANSIBLE_PLAYBOOK ?= ansible-playbook
VAGRANT ?= vagrant

.DEFAULT_GOAL := help

.PHONY: help deps up deploy all check reset reset-soft down destroy status flags ping lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

deps: ## Install Ansible collections + Python deps on the control node
	python3 -m pip install -r requirements.txt
	ansible-galaxy collection install -r requirements.yml

up: ## Create/boot all VMs (no domain provisioning yet)
	$(VAGRANT) up

deploy: ## Provision the whole lab with Ansible (domain, vulns, flags)
	$(ANSIBLE_PLAYBOOK) site.yml

all: up deploy ## Full build: boot VMs then provision everything

check: ## Dry-run the full provision (no changes made)
	$(ANSIBLE_PLAYBOOK) site.yml --check --diff

reset: ## HARD reset: destroy and rebuild the entire lab (pristine)
	$(VAGRANT) destroy -f
	$(VAGRANT) up
	$(ANSIBLE_PLAYBOOK) site.yml
	@echo ">>> Lab rebuilt clean."

reset-soft: ## SOFT reset: re-plant AD/vulns/flags without rebuilding VMs
	$(ANSIBLE_PLAYBOOK) playbooks/reset.yml

flags: ## List every flag and where it is gated (spoiler)
	@./scripts/check-flags.sh

ping: ## Connectivity check to all hosts (WinRM + SSH)
	ansible windows -m ansible.windows.win_ping || true
	ansible linux_pivot -m ansible.builtin.ping || true

lint: ## Lint playbooks and YAML (needs ansible-lint + yamllint)
	yamllint . || true
	ansible-lint || true

status: ## Show VM status
	$(VAGRANT) status

down: ## Gracefully halt all VMs (keep disks)
	$(VAGRANT) halt

destroy: ## Destroy all VMs and free disk
	$(VAGRANT) destroy -f
