resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# Internal-only environment: apps get a private IP in snet-aca and no public endpoint.
resource "azurerm_container_app_environment" "this" {
  name                           = "cae-${var.prefix}"
  location                       = azurerm_resource_group.this.location
  resource_group_name            = azurerm_resource_group.this.name
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id       = azurerm_subnet.aca.id
  internal_load_balancer_enabled = true
  tags                           = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  lifecycle {
    # Azure creates a managed infrastructure resource group; ignore its generated name.
    ignore_changes = [infrastructure_resource_group_name]
  }
}

# Resolve <app>.<env default domain> to the environment's internal IP from the hub (where the
# PNG lands) and the spoke. Azure-provided DNS picks this up, so PNG needs no custom resolver.
resource "azurerm_private_dns_zone" "aca" {
  name                = azurerm_container_app_environment.this.default_domain
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "aca_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.aca.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
}

resource "azurerm_private_dns_a_record" "aca_apex" {
  name                = "@"
  zone_name           = azurerm_private_dns_zone.aca.name
  resource_group_name = azurerm_resource_group.this.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
}

resource "azurerm_private_dns_zone_virtual_network_link" "aca_hub" {
  name                  = "link-hub"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.aca.name
  virtual_network_id    = azurerm_virtual_network.hub.id
  tags                  = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aca_spoke" {
  name                  = "link-spoke"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.aca.name
  virtual_network_id    = azurerm_virtual_network.spoke.id
  tags                  = local.tags
}
