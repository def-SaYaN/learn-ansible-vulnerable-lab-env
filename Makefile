# ===========================================================================
#  learn-ansible-vulnerable-lab-env  --  Makefile
#  AWS lifecycle: Terraform provisions the VMs, Ansible configures the lab.
#  Terraform commands run inside ./terraform; Ansible runs from the repo root
#  against the generated inventory/hosts.ini.
# ===========================================================================
SHELL := /bin/bash
ANSIBLE_PLAYBOOK ?= ansible-playbook
TERRAFORM        ?= terraform
TF_DIR           ?= terraform

.DEFAULT_GOAL := help

.PHONY: help deps tf-init tf-plan tf-apply tf-destroy up deploy all check reset-soft ping flags lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

deps: ## Install Ansible collections + Python deps on the control node
	python3 -m pip install -r requirements.txt
	ansible-galaxy collection install -r requirements.yml

tf-init: ## Terraform: download providers / initialise (run once)
	cd $(TF_DIR) && $(TERRAFORM) init

tf-plan: ## Terraform: preview the infrastructure changes (no changes made)
	cd $(TF_DIR) && $(TERRAFORM) plan

tf-apply: ## Terraform: create the AWS VMs and generate inventory/hosts.ini
	cd $(TF_DIR) && $(TERRAFORM) apply

tf-destroy: ## Terraform: tear down all AWS resources (stop paying)
	cd $(TF_DIR) && $(TERRAFORM) destroy

up: tf-apply ## Alias for tf-apply (Job 1: provision the VMs)

ping: ## Connectivity check (WinRM + SSH) against the generated inventory
	ansible windows -m ansible.windows.win_ping || true
	ansible linux_pivot -m ansible.builtin.ping || true

deploy: ## Job 2: provision the whole lab with Ansible (domain, vulns, flags)
	$(ANSIBLE_PLAYBOOK) site.yml

all: tf-apply deploy ## Full build: create the VMs (Terraform) then configure (Ansible)

check: ## Dry-run the Ansible provision (no changes made)
	$(ANSIBLE_PLAYBOOK) site.yml --check --diff

reset-soft: ## Re-plant AD content / vulns / flags without rebuilding the VMs
	$(ANSIBLE_PLAYBOOK) playbooks/reset.yml

flags: ## List every flag and where it is gated (spoiler)
	@./scripts/check-flags.sh

lint: ## Lint YAML + Ansible (needs yamllint + ansible-lint)
	yamllint . || true
	ansible-lint || true
