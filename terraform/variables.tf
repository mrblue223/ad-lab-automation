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
}

variable "admin_password" {
  description = "Local admin password for the VMs. Must meet Azure complexity (12+ chars, 3 of 4 classes). Set in terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "vm_size" {
  description = "VM size. B2s (2 vCPU / 4 GB) is enough for a lab and cheap."
  type        = string
  default     = "Standard_B2s"
}

variable "allowed_source_ip" {
  description = "Your public IP (x.x.x.x/32) — locks RDP/WinRM to just you. Get it: curl ifconfig.me"
  type        = string
}

variable "address_space" {
  description = "VNet address space — matches the lab's 10.0.2.0/24"
  type        = string
  default     = "10.0.2.0/24"
}

# Static private IPs — must line up with ansible group_vars
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
