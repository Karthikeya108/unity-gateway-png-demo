resource "azurerm_resource_group" "this" {
  name     = "rg-${var.prefix}-ne"
  location = var.location
  tags     = local.tags
}

# Hub: holds the subnet delegated to Databricks for the private network gateway.
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.prefix}-hub"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.hub_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "png" {
  name                 = "snet-png"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.png_subnet_prefix]

  delegation {
    name = "databricks-png"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
    }
  }

  lifecycle {
    # Azure fills in the delegation actions; don't fight it.
    ignore_changes = [delegation[0].service_delegation[0].actions]
  }
}

# Spoke: the internal "tools" network hosting the MCP servers.
resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-${var.prefix}-spoke"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.spoke_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "aca" {
  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [var.aca_subnet_prefix]

  delegation {
    name = "container-apps"
    service_delegation {
      name = "Microsoft.App/environments"
    }
  }

  lifecycle {
    ignore_changes = [delegation[0].service_delegation[0].actions]
  }
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "hub-to-spoke"
  resource_group_name       = azurerm_resource_group.this.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "spoke-to-hub"
  resource_group_name       = azurerm_resource_group.this.name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
}
