variable "deploy_mcp_apps" {
  description = "Create the MCP container apps (set after the image is built into ACR)."
  type        = bool
  default     = true
}

variable "mcp_image_tag" {
  type    = string
  default = "v1"
}

variable "mcp_api_app_id" {
  description = "Entra appId of png-demo-mcp-api (audience). From .state/entra.env (MCP_API_APP_ID)."
  type        = string
}

variable "mcp_client_app_id" {
  description = "Entra appId of png-demo-mcp-client (allowed caller, the UC connection's OAuth app). From .state/entra.env."
  type        = string
}

variable "demo_users" {
  description = "UPNs that own seeded requests (comma-separated), e.g. demo user A and B. Keep in sync with the bundle."
  type        = string
}

resource "azurerm_container_registry" "this" {
  name                = "acr${var.prefix}${random_string.suffix.result}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

# Pull identity for the container apps (no registry passwords).
resource "azurerm_user_assigned_identity" "mcp" {
  name                = "id-${var.prefix}-mcp"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "mcp_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.mcp.principal_id
}

# Internal MCP servers, one container app each. Adding a server here is all the networking it needs:
# every app gets <name>.<environment domain>, which the private DNS wildcard and the PNG destination
# (the environment domain suffix) already cover. Use "server" for a tool set of the bundled image
# (mcp/server.py SERVER=...), or "image" for your own MCP server image in this registry.
variable "mcp_servers" {
  type = map(object({
    server = optional(string)
    image  = optional(string)
  }))
  default = {
    "service-desk-mcp"    = { server = "service_desk" }
    "asset-inventory-mcp" = { server = "asset_inventory" }
  }
}

resource "azurerm_container_app" "mcp" {
  for_each = var.deploy_mcp_apps ? var.mcp_servers : {}

  name                         = each.key
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.mcp.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.mcp.id
  }

  # In an internal environment "external" means reachable from the VNet (and so via PNG),
  # not from the internet.
  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # One replica: the demo data lives in memory, so writes stay consistent across calls.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "mcp"
      image  = "${azurerm_container_registry.this.login_server}/${coalesce(each.value.image, "internal-mcp:${var.mcp_image_tag}")}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "SERVER"
        value = coalesce(each.value.server, "custom")
      }
      env {
        name  = "TENANT_ID"
        value = var.tenant_id
      }
      env {
        name  = "MCP_API_APP_ID"
        value = var.mcp_api_app_id
      }
      env {
        name  = "ALLOWED_CLIENT_IDS"
        value = var.mcp_client_app_id
      }
      env {
        name  = "DEMO_USERS"
        value = var.demo_users
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/healthz"
      }
    }
  }

  depends_on = [azurerm_role_assignment.mcp_acr_pull]
}

output "acr_name" {
  value = azurerm_container_registry.this.name
}

output "mcp_urls" {
  description = "Internal MCP endpoints (reachable only from the VNet / via PNG)."
  value       = { for k, app in azurerm_container_app.mcp : k => "https://${app.ingress[0].fqdn}/mcp" }
}
