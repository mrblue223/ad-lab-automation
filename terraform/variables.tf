# ---- Input variables -------------------------------------------------------

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group to create for the lab"
  type        = string
  default     = "rg-adlab-marvel"
}

variable "admin_username" {
  description = "Local admin username baked into each Windows VM (used by Ansible over WinRM)"
  type        = string
  default     = "azureadmin"

  validation {
    condition     = !contains(["administrator", "admin", "guest", "user", "root", "test"], lower(var.admin_username))
    error_message = "Azure rejects reserved admin usernames such as 'Administrator' or 'admin'."
  }
}

variable "admin_password" {
  description = "Local admin password for the VMs (12-123 chars, 3 of 4 classes). Set in terraform.tfvars."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 12 && length(var.admin_password) <= 123
    error_message = "admin_password must be 12-123 characters (Azure requirement)."
  }
}

# Defaults fit a 4-vCPU regional quota (Free Trial / Students): 2 + 1 + 1.
# B-series is no longer offered to many subscriptions — check yours with:
#   az vm list-skus -l <region> --resource-type virtualMachines --query "[?restrictions==\`[]\`].name" -o tsv
#   az vm list-usage -l <region> -o table
variable "vm_size" {
  description = "DC VM size (x64, Gen2). Default: 2 vCPU / 4 GB AMD, NVMe-only."
  type        = string
  default     = "Standard_D2als_v7"
}

variable "ws_vm_size" {
  description = "Workstation VM size. Default: 1 vCPU / 4 GB (fits the 4-vCPU quota). With more quota, use vm_size's value. null = same as vm_size."
  type        = string
  default     = "Standard_F1as_v7"
}

variable "disk_controller_type" {
  description = "\"NVMe\" for v6/v7 sizes (NVMe-only), \"SCSI\" for older sizes (e.g. B-series, Dsv4). Must be supported by both sizes and images."
  type        = string
  default     = "NVMe"

  validation {
    condition     = contains(["NVMe", "SCSI"], var.disk_controller_type)
    error_message = "disk_controller_type must be \"NVMe\" or \"SCSI\"."
  }
}

# ---- Access ----------------------------------------------------------------
variable "access_mode" {
  description = <<-EOT
    How your Kali reaches the lab:
      "tailscale" (default) — NO public IPs, NO inbound internet rules. HYDRA-DC joins your
                              tailnet and advertises the lab subnet; you hit 10.0.2.x directly.
      "public"    (fallback) — public IPs + NSG locked to allowed_source_ip (/32).
  EOT
  type        = string
  default     = "tailscale"

  validation {
    condition     = contains(["tailscale", "public"], var.access_mode)
    error_message = "access_mode must be \"tailscale\" or \"public\"."
  }
}

variable "allowed_source_ip" {
  description = "Your public IP as x.x.x.x/32. Only used when access_mode = \"public\" (make azure-myip keeps it current)."
  type        = string
  default     = null

  validation {
    condition     = var.allowed_source_ip == null ? true : (can(cidrhost(var.allowed_source_ip, 0)) && endswith(var.allowed_source_ip, "/32"))
    error_message = "allowed_source_ip must be a single IPv4 host in CIDR form, e.g. 198.51.100.7/32 (never 0.0.0.0/0)."
  }
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key (tagged, reusable, NOT ephemeral). Only read when the DC's bootstrap first runs. Pass via TF_VAR_tailscale_auth_key / deploy-azure.sh — never put it in tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tailscale_hostname" {
  description = "Machine name HYDRA-DC gets in your tailnet"
  type        = string
  default     = "marvel-hydra-dc"
}

variable "tailscale_tags" {
  description = "ACL tags the DC advertises. Must match the auth key's tags and be owned in your tailnet policy (see documentation/tailscale.md)."
  type        = list(string)
  default     = ["tag:adlab"]
}

variable "enable_nat_gateway" {
  description = "Outbound internet for the private VMs. false = Azure default outbound access (free, implicit). true = NAT Gateway (~$33/month, bills even while VMs are deallocated)."
  type        = bool
  default     = false
}

variable "address_space" {
  description = "VNet address space — matches the lab's 10.0.2.0/24 (ansible group_vars subnet_cidr)"
  type        = string
  default     = "10.0.2.0/24"
}

# Static private IPs — must line up with ansible/group_vars/all.yml
variable "dc_private_ip" {
  type    = string
  default = "10.0.2.10"
}

variable "workstation_ips" {
  type = map(string)
  default = {
    THEPUNISHER = "10.0.2.11"
    SPIDERMAN   = "10.0.2.12"
  }
}

# ---- Images ----------------------------------------------------------------
# Find valid values for your region with, e.g.:
#   az vm image list-skus -l eastus -p MicrosoftWindowsDesktop -f windows-11 -o table
#   az vm image list-skus -l eastus -p MicrosoftWindowsDesktop -f Windows-10 -o table
#   az vm image list-skus -l eastus -p MicrosoftWindowsServer  -f WindowsServer -o table
#   az vm image show -l eastus --urn MicrosoftWindowsDesktop:windows-11:win11-25h2-pro:latest

variable "dc_image" {
  description = "Marketplace image for HYDRA-DC"
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }
}

variable "workstation_os" {
  description = "\"client\" = Windows 10/11 (matches the course). \"server\" = Windows Server fallback when no client SKU deploys on your subscription."
  type        = string
  default     = "client"

  validation {
    condition     = contains(["client", "server"], var.workstation_os)
    error_message = "workstation_os must be \"client\" or \"server\"."
  }
}

variable "ws_client_image" {
  description = "Windows client image for the workstations (used when workstation_os = \"client\")"
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-25h2-pro"
    version   = "latest"
  }
}

variable "ws_server_image" {
  description = "Fallback image for the workstations (used when workstation_os = \"server\") — available in every public region"
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }
}

variable "ws_license_type" {
  description = "Set to \"Windows_Client\" to attest multi-tenant hosting rights for Windows 10/11 (e.g. Visual Studio subscription). Leave null otherwise."
  type        = string
  default     = null
}

variable "enable_trusted_launch" {
  description = "Secure Boot + vTPM. Win11 and Server 2022 Azure Edition support it; disable if you pick an image/size that doesn't."
  type        = bool
  default     = true
}
