# =============================================================================
#  vms.tf — the three Windows VMs
#  HYDRA-DC (Server 2022) + THEPUNISHER/SPIDERMAN (Windows 11, or Server fallback).
#
#  access_mode = "tailscale": NO public IPs. HYDRA-DC joins your tailnet and
#    advertises 10.0.2.0/24, so your Kali reaches every VM at its private IP.
#  access_mode = "public": each VM gets a Standard public IP, NSG-locked to
#    allowed_source_ip.
# =============================================================================

locals {
  ws_image   = var.workstation_os == "client" ? var.ws_client_image : var.ws_server_image
  ws_vm_size = coalesce(var.ws_vm_size, var.vm_size)
  tailnet    = var.access_mode == "tailscale"
  public     = var.access_mode == "public"

  # One bootstrap per VM, rendered from the template (only HYDRA-DC installs
  # Tailscale). Delivered by managed Run Command as a plain .ps1 FILE. Never
  # wrap it in an encoded/compressed in-memory loader: Defender's behaviour
  # monitor kills that as Behavior:Win32/PShellCobStager and the run "succeeds"
  # silently. The Tailscale key is a protected parameter, not script text.
  bootstrap = {
    for name in concat(["HYDRA-DC"], keys(var.workstation_ips)) : name => templatefile(
      "${path.module}/scripts/bootstrap.ps1.tftpl", {
        tailnet           = local.tailnet
        install_tailscale = local.tailnet && name == "HYDRA-DC"
        hostname          = var.tailscale_hostname
        routes            = var.address_space
        tags              = join(",", var.tailscale_tags)
      }
    )
  }

  all_vm_ids = merge(
    { "HYDRA-DC" = azurerm_windows_virtual_machine.dc.id },
    { for k, v in azurerm_windows_virtual_machine.ws : k => v.id }
  )

  # Address Ansible + your tools use for each VM.
  access_address = merge(
    { "HYDRA-DC" = local.public ? azurerm_public_ip.dc[0].ip_address : var.dc_private_ip },
    { for k, ip in var.workstation_ips : k => local.public ? azurerm_public_ip.ws[k].ip_address : ip }
  )
}

# ---------- Public IPs (access_mode = "public" only) ----------
# Standard SKU: Basic public IPs were retired by Azure in Sept 2025.
# Standard IPs are closed by default; only the NSG rules open them.
resource "azurerm_public_ip" "dc" {
  count               = local.public ? 1 : 0
  name                = "pip-hydra-dc"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "ws" {
  for_each            = local.public ? var.workstation_ips : {}
  name                = "pip-${lower(each.key)}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ---------- NICs (static private IPs matching the lab plan) ----------
# Azure delivers these via DHCP reservation — the guest must stay on DHCP.
resource "azurerm_network_interface" "dc" {
  name                = "nic-hydra-dc"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  # HYDRA-DC forwards tailnet <-> lab traffic, so Azure must accept packets
  # it sends/receives on behalf of other addresses.
  ip_forwarding_enabled = local.tailnet

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.dc_private_ip
    public_ip_address_id          = local.public ? azurerm_public_ip.dc[0].id : null
  }
}

resource "azurerm_network_interface" "ws" {
  for_each            = var.workstation_ips
  name                = "nic-${lower(each.key)}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value
    public_ip_address_id          = local.public ? azurerm_public_ip.ws[each.key].id : null
  }
}

# ---------- Domain Controller ----------
resource "azurerm_windows_virtual_machine" "dc" {
  name                  = "HYDRA-DC"
  computer_name         = "HYDRA-DC"
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.dc.id]
  secure_boot_enabled   = var.enable_trusted_launch
  vtpm_enabled          = var.enable_trusted_launch
  disk_controller_type  = var.disk_controller_type

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  # Azure turns this on for new VMs; azurerm 3.x models it as false, which
  # would otherwise show a perpetual in-place "update" on every plan.
  lifecycle {
    ignore_changes = [vm_agent_platform_updates_enabled]
  }

  source_image_reference {
    publisher = var.dc_image.publisher
    offer     = var.dc_image.offer
    sku       = var.dc_image.sku
    version   = var.dc_image.version
  }
}

# ---------- Workstations ----------
resource "azurerm_windows_virtual_machine" "ws" {
  for_each              = var.workstation_ips
  name                  = each.key
  computer_name         = each.key
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  size                  = local.ws_vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.ws[each.key].id]
  license_type          = var.workstation_os == "client" ? var.ws_license_type : null
  secure_boot_enabled   = var.enable_trusted_launch
  vtpm_enabled          = var.enable_trusted_launch
  disk_controller_type  = var.disk_controller_type

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  # Azure turns this on for new VMs; azurerm 3.x models it as false, which
  # would otherwise show a perpetual in-place "update" on every plan.
  lifecycle {
    ignore_changes = [vm_agent_platform_updates_enabled]
  }

  source_image_reference {
    publisher = local.ws_image.publisher
    offer     = local.ws_image.offer
    sku       = local.ws_image.sku
    version   = local.ws_image.version
  }
}

# ---------- Bootstrap every VM (WinRM/HTTPS; + Tailscale on HYDRA-DC) ----------
# Managed Run Command: Azure writes source.script to a .ps1 on the VM and runs it
# synchronously; instance_view reports the real exit code, so a failing script
# fails `terraform apply` (postcondition) instead of "succeeding" silently.
# It re-runs whenever the script changes or the resource is replaced
# (deploy-azure.sh replaces any whose last run failed).
resource "azurerm_virtual_machine_run_command" "bootstrap" {
  for_each           = local.all_vm_ids
  name               = "lab-bootstrap"
  location           = azurerm_resource_group.lab.location
  virtual_machine_id = each.value

  source {
    script = local.bootstrap[each.key]
  }

  # Encrypted, never shown in the run command's properties or instance view.
  # Only HYDRA-DC gets it, and only when a key is supplied (Azure rejects empty
  # values). nonsensitive() exposes only WHETHER a key is set, never the key.
  dynamic "protected_parameter" {
    for_each = each.key == "HYDRA-DC" && nonsensitive(var.tailscale_auth_key != "") ? [1] : []
    content {
      name  = "TsAuthKey"
      value = var.tailscale_auth_key
    }
  }

  lifecycle {
    # The key is only supplied when the DC's bootstrap has to (re)run; don't
    # treat its absence on later runs as a change that re-executes the script.
    ignore_changes = [protected_parameter]

    postcondition {
      condition = try(self.instance_view[0].exit_code, 1) == 0
      error_message = join("", [
        "Bootstrap on ${each.key} failed (exit ${try(self.instance_view[0].exit_code, "?")}, ",
        "${try(self.instance_view[0].execution_state, "?")}): ",
        trimspace(try(self.instance_view[0].error_message, "")),
        " | Log on the VM: C:\\WindowsAzure\\lab-bootstrap.log. Fix the cause, then re-run ./deploy-azure.sh ",
        "(it re-runs only failed bootstraps)."
      ])
    }
  }

  timeouts {
    create = "40m"
    update = "40m"
  }
}
