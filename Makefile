# =============================================================================
#  AD Lab — one-command deploy. `make help` to see targets.
# =============================================================================
.PHONY: help azure azure-down deps up-local destroy-local configure check

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

# ---------- CLOUD: the one button ----------
azure:  ## ONE BUTTON: build + configure the whole lab in Azure
	./deploy-azure.sh

azure-down:  ## Destroy the Azure lab (stop paying)
	./destroy-azure.sh

# ---------- LOCAL (VirtualBox + Vagrant) ----------
deps:  ## Install Ansible collections (run once)
	ansible-galaxy collection install -r ansible/requirements.yml

up-local:  ## Build VMs locally, then configure the domain
	cd vagrant && vagrant up
	$(MAKE) configure INV=vagrant.ini

destroy-local:  ## Tear down the local VMs
	cd vagrant && vagrant destroy -f

# ---------- Shared configuration step ----------
INV ?= vagrant.ini
configure:  ## Configure the domain via Ansible (INV=vagrant.ini|azure_generated.ini)
	cd ansible && ansible-playbook -i inventory/$(INV) site.yml

check:  ## Health-check all hosts (needs netexec); use DC=<ip> for Azure
	nxc smb $(or $(DC),10.0.2.10)
