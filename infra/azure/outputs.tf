output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "png_subnet_id" {
  description = "Delegated subnet for the private network gateway."
  value       = azurerm_subnet.png.id
}

output "aca_environment_id" {
  value = azurerm_container_app_environment.this.id
}

output "aca_default_domain" {
  description = "PNG destination (SPECIFIC_DESTINATIONS) — covers every MCP app in the environment."
  value       = azurerm_container_app_environment.this.default_domain
}

output "aca_static_ip" {
  value = azurerm_container_app_environment.this.static_ip_address
}

output "storage_account_id" {
  description = "Target of the NCC private endpoint rules (dfs, blob)."
  value       = azurerm_storage_account.this.id
}

output "storage_account_name" {
  value = azurerm_storage_account.this.name
}

output "managed_location_url" {
  description = "Catalog MANAGED LOCATION."
  value       = "abfss://${azurerm_storage_container.ops_demo.name}@${azurerm_storage_account.this.name}.dfs.core.windows.net/"
}

output "access_connector_id" {
  description = "Used by the UC storage credential."
  value       = azurerm_databricks_access_connector.this.id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}
