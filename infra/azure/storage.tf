resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# Identity Unity Catalog uses to access the catalog's managed location.
resource "azurerm_databricks_access_connector" "this" {
  name                = "ac-${var.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

# ADLS Gen2 for the catalog managed location. Network default Deny with no IP rules:
# serverless reaches it only through NCC private endpoints; UC control-plane operations go
# through the Access Connector via the resource-instance rule.
resource "azurerm_storage_account" "this" {
  name                            = "st${var.prefix}${random_string.suffix.result}"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true
  tags                            = local.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["None"]

    private_link_access {
      endpoint_resource_id = azurerm_databricks_access_connector.this.id
      endpoint_tenant_id   = var.tenant_id
    }
  }
}

# Created through the management plane (storage_account_id), so it works with network Deny.
resource "azurerm_storage_container" "ops_demo" {
  name                  = "ops-demo"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Least privilege: data access on this storage account only.
resource "azurerm_role_assignment" "ac_blob_contributor" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.this.identity[0].principal_id
}

# Storage request logs (endpoint, caller IP, auth type) — used to verify that serverless reaches the
# managed location through the private endpoints (dfs) and never from public IPs.
resource "azurerm_monitor_diagnostic_setting" "storage_blob" {
  name                       = "png-demo-storage-logs"
  target_resource_id         = "${azurerm_storage_account.this.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}
