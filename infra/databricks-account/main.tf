terraform {
  required_version = ">= 1.6"
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.139"
    }
  }
}

# Account-level OAuth (U2M) through the Databricks CLI profile. No PATs.
provider "databricks" {
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.account_id
  profile    = var.account_profile
}

variable "account_id" {
  description = "Databricks account ID."
  type        = string
}

variable "account_profile" {
  description = "Databricks CLI profile for the account console (account admin, OAuth U2M)."
  type        = string
}

variable "workspace_id" {
  description = "Workspace to attach the NCC to (must be in the same region)."
  type        = number
}

variable "region" {
  type    = string
  default = "northeurope"
}

variable "enable_png" {
  description = "Create the private network gateway (toggle off to show the 'before' state in the demo)."
  type        = bool
  default     = true
}

variable "png_bandwidth_gbps" {
  type    = number
  default = 10
}

variable "group_members" {
  description = "Account users per demo group (user names / emails)."
  type        = map(list(string))
  default = {
    "png-demo-admins"      = []
    "png-demo-users"       = []
    "png-demo-assets-only" = []
  }
}

data "terraform_remote_state" "azure" {
  backend = "local"
  config = {
    path = "${path.module}/../azure/terraform.tfstate"
  }
}

locals {
  azure = data.terraform_remote_state.azure.outputs
}

# ---------- Account groups ----------

resource "databricks_group" "demo" {
  for_each     = var.group_members
  display_name = each.key
}

data "databricks_user" "members" {
  for_each  = toset(flatten(values(var.group_members)))
  user_name = each.value
}

resource "databricks_group_member" "demo" {
  for_each = { for pair in flatten([
    for g, users in var.group_members : [for u in users : { key = "${g}/${u}", group = g, user = u }]
  ]) : pair.key => pair }

  group_id  = databricks_group.demo[each.value.group].id
  member_id = data.databricks_user.members[each.value.user].id
}

# Make the account groups usable in the workspace (USER, not ADMIN).
resource "databricks_mws_permission_assignment" "demo" {
  for_each     = databricks_group.demo
  workspace_id = var.workspace_id
  principal_id = each.value.id
  permissions  = ["USER"]
}

# ---------- NCC: one object, two private paths ----------

resource "databricks_mws_network_connectivity_config" "this" {
  name   = "png-demo-ncc-ne"
  region = var.region
}

# Path 1 — Private Link to the catalog's managed-location storage (cloud-managed resource).
resource "databricks_mws_ncc_private_endpoint_rule" "storage" {
  for_each = toset(["dfs", "blob"])

  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  resource_id                    = local.azure.storage_account_id
  group_id                       = each.value
}

# Path 2 — private network gateway into the VNet (self-hosted MCP servers).
resource "databricks_private_network_gateway" "this" {
  count = var.enable_png ? 1 : 0

  parent                             = "accounts/${var.account_id}/network-connectivity-configs/${databricks_mws_network_connectivity_config.this.network_connectivity_config_id}"
  display_name                       = "png-demo-gateway"
  bandwidth_tier_gigabits_per_second = var.png_bandwidth_gbps
  traffic_mode                       = "SPECIFIC_DESTINATIONS"
  azure_cloud_connection = {
    gateway_subnet = {
      resource_id = local.azure.png_subnet_id
    }
  }
  # One suffix covers every MCP app in the Container Apps environment.
  destinations = [{
    destination_type = "DNS_NAME"
    value            = local.azure.aca_default_domain
  }]
  # Azure-provided DNS (private DNS zone linked to the hub VNet).
  private_dns_resolvers = []
}

resource "databricks_mws_ncc_binding" "this" {
  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  workspace_id                   = var.workspace_id
}

output "ncc_id" {
  value = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
}

output "private_endpoint_rules" {
  value = { for k, r in databricks_mws_ncc_private_endpoint_rule.storage : k => {
    endpoint_name    = r.endpoint_name
    connection_state = r.connection_state
  } }
}

output "png" {
  value = var.enable_png ? {
    name  = databricks_private_network_gateway.this[0].name
    state = databricks_private_network_gateway.this[0].state
  } : null
}

output "group_ids" {
  value = { for k, g in databricks_group.demo : k => g.id }
}
