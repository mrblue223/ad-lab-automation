# =============================================================================
#  network.tf — VNet, subnet, NSG, routing, outbound
#  All lab hosts share one subnet (10.0.2.0/24).
#
#  Inbound from the internet:
#    tailscale mode -> NONE. No public IPs exist, and rule 4000 denies the
#                      Internet tag regardless (defence in depth).
#    public mode    -> management + AD ports from allowed_source_ip (/32) only.
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

  # Private VMs still need OUTBOUND internet (Tailscale coordination, Windows
  # activation). Azure is retiring implicit outbound for new VNets, so opt in
  # explicitly — or use the NAT gateway below.
  default_outbound_access_enabled = !var.enable_nat_gateway
}

resource "azurerm_network_security_group" "lab" {
  name                = "nsg-adlab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  # --- public mode only: management (RDP + WinRM/HTTPS) from your IP ---
  # 5985 (WinRM over HTTP) is deliberately never opened.
  dynamic "security_rule" {
    for_each = local.public ? [1] : []
    content {
      name                       = "AllowMgmtFromMe"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_ranges    = ["3389", "5986"]
      source_address_prefix      = var.allowed_source_ip
      destination_address_prefix = "*"
    }
  }

  # --- public mode only: AD / pentest attack surface from your IP ---
  dynamic "security_rule" {
    for_each = local.public ? [1] : []
    content {
      name              = "AllowADAttackFromMe"
      priority          = 110
      direction         = "Inbound"
      access            = "Allow"
      protocol          = "*"
      source_port_range = "*"
      destination_port_ranges = [
        "53", "88", "135", "139", "389", "445", "464", "636", "3268", "3269",
        "49152-65535", # RPC dynamic range (DCSync/psexec)
      ]
      source_address_prefix      = var.allowed_source_ip
      destination_address_prefix = "*"
    }
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

  # --- tailscale mode: your tailnet, forwarded by HYDRA-DC ---
  # 100.64.0.0/10 can only enter the VNet via the DC's tunnel: there are no
  # public IPs, and rule 4000 blocks the Internet tag.
  dynamic "security_rule" {
    for_each = local.tailnet ? [1] : []
    content {
      name                       = "AllowTailnetViaDC"
      priority                   = 130
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "100.64.0.0/10"
      destination_address_prefix = var.address_space
    }
  }

  # --- Always: explicit deny of anything from the internet ---
  # Azure's DenyAllInBound (65500) already does this; stating it at 4000 means a
  # later careless rule above 4000 can't open the lab by accident.
  security_rule {
    name                       = "DenyInternetInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  lifecycle {
    precondition {
      condition     = !local.public || var.allowed_source_ip != null
      error_message = "access_mode = \"public\" needs allowed_source_ip (your IP /32). Run: make azure-myip"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "lab" {
  subnet_id                 = azurerm_subnet.lab.id
  network_security_group_id = azurerm_network_security_group.lab.id
}

# ---------- Return path for tailnet traffic ----------
# Replies from the workstations to your Kali (100.x) must go back through
# HYDRA-DC's tunnel, not out to Azure's default route.
resource "azurerm_route_table" "lab" {
  count               = local.tailnet ? 1 : 0
  name                = "rt-adlab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  route {
    name                   = "tailnet-via-hydra-dc"
    address_prefix         = "100.64.0.0/10"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.dc_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "lab" {
  count          = local.tailnet ? 1 : 0
  subnet_id      = azurerm_subnet.lab.id
  route_table_id = azurerm_route_table.lab[0].id
}

# ---------- Optional NAT gateway for outbound ----------
resource "azurerm_public_ip" "nat" {
  count               = var.enable_nat_gateway ? 1 : 0
  name                = "pip-nat-adlab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "lab" {
  count               = var.enable_nat_gateway ? 1 : 0
  name                = "nat-adlab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "lab" {
  count                = var.enable_nat_gateway ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.lab[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "lab" {
  count          = var.enable_nat_gateway ? 1 : 0
  subnet_id      = azurerm_subnet.lab.id
  nat_gateway_id = azurerm_nat_gateway.lab[0].id
}
