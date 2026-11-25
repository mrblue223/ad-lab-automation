# =============================================================================
#  network.tf — VNet, subnet, NSG
#  All lab hosts share one subnet (10.0.2.0/24) so intra-lab AD traffic flows
#  freely. The NSG opens the AD attack surface to YOUR IP only, so you can run
#  the whole engagement from your home Kali over the internet.
# =============================================================================

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-adlab"
  address_space       = [var.address_space]
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_subnet" "lab" {
  name                 = "snet-adlab"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.address_space]
}

resource "azurerm_network_security_group" "lab" {
  name                = "nsg-adlab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  # --- Management (RDP + WinRM) from your IP only ---
  security_rule {
    name                       = "AllowMgmtFromMe"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["3389", "5985", "5986"]
    source_address_prefix      = var.allowed_source_ip
    destination_address_prefix = "*"
  }

  # --- AD / pentest attack surface from your IP only ---
  # Lets your home Kali run Kerberoasting, LDAP enum, BloodHound, SMB,
  # DCSync, psexec, pass-the-hash, etc. straight against the lab.
  security_rule {
    name                       = "AllowADAttackFromMe"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges = [
      "53",    # DNS
      "88",    # Kerberos
      "135",   # RPC endpoint mapper
      "139",   # NetBIOS
      "389",   # LDAP
      "445",   # SMB
      "464",   # kpasswd
      "636",   # LDAPS
      "3268",  # Global Catalog
      "3269",  # Global Catalog SSL
      "49152-65535" # RPC dynamic range (DCSync/psexec)
    ]
    source_address_prefix      = var.allowed_source_ip
    destination_address_prefix = "*"
  }

  # --- Intra-subnet: lab hosts talk freely to each other ---
  security_rule {
    name                       = "AllowIntraSubnet"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.address_space
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "lab" {
  subnet_id                 = azurerm_subnet.lab.id
  network_security_group_id = azurerm_network_security_group.lab.id
}
