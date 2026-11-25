# =============================================================================
#  AD Lab — one-command deploy. `make help` to see targets.
# =============================================================================
.PHONY: help setup audit azure azure-down azure-stop azure-start azure-myip azure-tailnet deps up-local destroy-local configure check lint validate

RG ?= rg-adlab-marvel

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

# ---------- CLOUD: the one button ----------
setup:  ## Interactive: your IP, VM password, Tailscale key, region -> gitignored files only
	./scripts/setup.sh

azure:  ## ONE BUTTON: build + configure the whole lab in Azure (run make setup first)
	./deploy-azure.sh

azure-stop:  ## Deallocate all lab VMs (stop compute billing, keep disks)
	az vm deallocate --ids $$(az vm list -g $(RG) --query "[].id" -o tsv)

azure-start:  ## Start the lab VMs again
	az vm start --ids $$(az vm list -g $(RG) --query "[].id" -o tsv)

azure-myip:  ## Set allowed_source_ip to your current IP (updates the NSG in public mode)
	./scripts/azure-myip.sh

azure-tailnet:  ## Check the Tailscale tunnel to the lab (tailscale mode)
	python3 scripts/tailnet-check.py kali
	python3 scripts/tailnet-check.py router --hostname $$(terraform -chdir=terraform output -raw tailscale_hostname) --subnet $$(terraform -chdir=terraform output -raw lab_subnet)

azure-down:  ## Destroy the Azure lab (stop paying entirely)
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
configure:  ## Configure the domain via Ansible (INV=vagrant.ini|azure_generated.yml)
	cd ansible && ansible-playbook -i inventory/$(INV) site.yml

check:  ## Health-check the DC (needs netexec); DC=<ip> for public mode
	nxc smb $(or $(DC),10.0.2.10) -u fcastle -p Password1 -d MARVEL.local

# ---------- Quality gates ----------
validate:  ## terraform fmt/validate + ansible syntax check
	terraform -chdir=terraform fmt -check -recursive
	terraform -chdir=terraform init -backend=false -input=false >/dev/null
	terraform -chdir=terraform validate
	cd ansible && ansible-playbook -i inventory/vagrant.ini --syntax-check site.yml

lint: validate  ## validate + ansible-lint + shellcheck
	cd ansible && ansible-lint .
	shellcheck -x deploy-azure.sh destroy-azure.sh scripts/*.sh

audit:  ## Prove no secrets / personal data in the working tree AND all git history
	python3 -I scripts/audit-secrets.py
	@! git ls-files | grep -iE 'tfvars|tfstate|bak|azure_generated|ATTACK_FROM|tskey|pem|key' || { echo "sensitive-looking file is tracked"; exit 1; }
