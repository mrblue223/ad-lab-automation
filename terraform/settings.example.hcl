# Reference only — DO NOT put real values in this (tracked) file.
#
# Your settings are collected at runtime by `make setup`, which writes them to
# terraform/terraform.tfvars (gitignored, mode 0600). Every *.tfvars file is
# gitignored. You can add any optional override below to that file yourself;
# re-running `make setup` keeps them.

# Access: "tailscale" (default) = NO public IPs; reach the lab over your tailnet
# (documentation/tailscale.md). The auth key is NEVER a tfvars entry: make setup
# stores it in .secrets/tailscale-authkey (gitignored, mode 0600).
# "public" = fallback: public IPs, NSG locked to allowed_source_ip.
# access_mode = "tailscale"

# Only used in public mode. Set by make setup; refresh with: make azure-myip
# (203.0.113.0/24 is the RFC 5737 documentation range — a placeholder.)
allowed_source_ip = "203.0.113.45/32"

# VM local admin password — 12+ chars, 3 of 4 character classes. Entered
# (hidden) by make setup.
# This is only the Ansible/RDP management credential; the lab's domain
# credentials live in ansible/group_vars/all.yml.
admin_password = "<SET_AT_RUNTIME>"

# ---- Optional overrides ----
# tailscale_hostname  = "marvel-hydra-dc"
# tailscale_tags      = ["tag:adlab"]
# enable_nat_gateway  = false   # true = NAT gateway outbound (~$33/mo, bills while deallocated)
# location            = "canadacentral"
# Sizes — defaults fit a 4-vCPU quota (2 + 1 + 1). With more quota, give the
# workstations 2 vCPUs too. Older SCSI-only sizes need disk_controller_type = "SCSI".
# vm_size              = "Standard_D2als_v7"
# ws_vm_size           = "Standard_F1as_v7"
# disk_controller_type = "NVMe"
# resource_group_name = "rg-adlab-marvel"

# Workstation image. Default is Windows 11 Pro 25H2 (client, matches the course).
# If no client SKU will deploy on your subscription/region, fall back to Server:
# workstation_os = "server"
#
# Or pick a different client SKU (list them with
#   az vm image list-skus -l <region> -p MicrosoftWindowsDesktop -f windows-11 -o table):
# ws_client_image = {
#   publisher = "MicrosoftWindowsDesktop"
#   offer     = "Windows-10"
#   sku       = "win10-22h2-pro-g2"
#   version   = "latest"
# }
#
# Visual Studio / MSDN subscribers can attest Windows client licensing:
# ws_license_type = "Windows_Client"
