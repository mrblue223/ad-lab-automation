# =============================================================================
#  vms.tf — the three Windows VMs
#  HYDRA-DC (Server 2022) + THEPUNISHER/SPIDERMAN (Windows 11).
#  Each gets a public IP (locked to your source IP by the NSG) and a WinRM/HTTPS
#  listener so Ansible can configure the domain afterwards.
# =============================================================================

# ---------- Public IPs ----------
resource "azurerm_public_ip" "dc" {
  name                = "pip-hydra-dc"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
}

resource "azurerm_public_ip" "ws" {
  for_each            = var.workstation_ips
  name                = "pip-${lower(each.key)}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
}

# ---------- NICs (static private IPs matching the lab plan) ----------
resource "azurerm_network_interface" "dc" {
  name                = "nic-hydra-dc"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.dc_private_ip
    public_ip_address_id          = azurerm_public_ip.dc.id
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
    public_ip_address_id          = azurerm_public_ip.ws[each.key].id
  }
}

# ---------- Domain Controller: Windows Server 2022 ----------
resource "azurerm_windows_virtual_machine" "dc" {
  name                  = "HYDRA-DC"
  computer_name         = "HYDRA-DC"
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.dc.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }
}

# ---------- Workstations: Windows 11 ----------
resource "azurerm_windows_virtual_machine" "ws" {
  for_each              = var.workstation_ips
  name                  = each.key
  computer_name         = each.key
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.ws[each.key].id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-23h2-pro"
    version   = "latest"
  }
}

# ---------- Enable WinRM/HTTPS on every VM (so Ansible can connect) ----------
# Uses Ansible's official ConfigureRemotingForAnsible.ps1 via CustomScript.
locals {
  winrm_setup_url = "https://raw.githubusercontent.com/ansible/ansible-documentation/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"
  all_vm_ids = merge(
    { "HYDRA-DC" = azurerm_windows_virtual_machine.dc.id },
    { for k, v in azurerm_windows_virtual_machine.ws : k => v.id }
  )
}

resource "azurerm_virtual_machine_extension" "winrm" {
  for_each             = local.all_vm_ids
  name                 = "enable-winrm"
  virtual_machine_id   = each.value
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = <<SETTINGS
    {
      "fileUris": ["${local.winrm_setup_url}"],
      "commandToExecute": "powershell -ExecutionPolicy Unrestricted -File ConfigureRemotingForAnsible.ps1"
    }
  SETTINGS
}
