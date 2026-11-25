# =============================================================================
#  main.tf — Azure deploy of the MARVEL.local lab
#  Resource group + provider. Network in network.tf, VMs in vms.tf.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags = {
    project = "ad-pentest-lab"
    domain  = "MARVEL.local"
    note    = "deliberately-vulnerable lab — deallocate when idle to save credits"
  }
}
