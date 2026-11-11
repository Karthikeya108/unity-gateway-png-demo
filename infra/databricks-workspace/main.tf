terraform {
  required_version = ">= 1.6"
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.139"
    }
  }
}

# Workspace-level OAuth (U2M) through the Databricks CLI profile.
provider "databricks" {
  profile = var.workspace_profile
}

variable "workspace_profile" {
  description = "Databricks CLI profile for the workspace (OAuth U2M)."
  type        = string
}

variable "catalog_name" {
  type    = string
  default = "ops_demo"
}

data "terraform_remote_state" "azure" {
  backend = "local"
  config  = { path = "${path.module}/../azure/terraform.tfstate" }
}

locals {
  azure  = data.terraform_remote_state.azure.outputs
  admins = "png-demo-admins"
  users  = "png-demo-users"
  assets = "png-demo-assets-only"
}

# ---------- Your own storage as the catalog managed location ----------

resource "databricks_storage_credential" "ops_demo" {
  name    = "png-demo-ac"
  comment = "Access Connector for the ops_demo managed location (firewalled ADLS, reached via NCC private endpoints)"
  azure_managed_identity {
    access_connector_id = local.azure.access_connector_id
  }
  owner = local.admins
}

resource "databricks_external_location" "ops_demo" {
  name            = "png-demo-ops"
  url             = local.azure.managed_location_url
  credential_name = databricks_storage_credential.ops_demo.name
  comment         = "Managed location of catalog ops_demo"
  owner           = local.admins
}

resource "databricks_catalog" "ops_demo" {
  name         = var.catalog_name
  storage_root = databricks_external_location.ops_demo.url
  comment      = "PNG demo: Delta history in your ADLS (Private Link) + MCP services for internal systems (PNG)"
  owner        = local.admins
}

resource "databricks_schema" "lakehouse" {
  catalog_name = databricks_catalog.ops_demo.name
  name         = "lakehouse"
  comment      = "Historical operations data (managed Delta tables)"
  owner        = local.admins
}

resource "databricks_schema" "tools" {
  catalog_name = databricks_catalog.ops_demo.name
  name         = "tools"
  comment      = "MCP services and connections for internal systems"
  owner        = local.admins
}

# ---------- Grants (least privilege) ----------

resource "databricks_grants" "catalog" {
  catalog = databricks_catalog.ops_demo.name
  grant {
    principal  = local.users
    privileges = ["USE_CATALOG"]
  }
  grant {
    principal  = local.assets
    privileges = ["USE_CATALOG"]
  }
}

resource "databricks_grants" "lakehouse" {
  schema = "${databricks_catalog.ops_demo.name}.${databricks_schema.lakehouse.name}"
  grant {
    principal  = local.users
    privileges = ["USE_SCHEMA", "SELECT"]
  }
  grant {
    principal  = local.assets
    privileges = ["USE_SCHEMA", "SELECT"]
  }
}

# End users get EXECUTE on individual MCP services (granted after the services are registered);
# here they only need USE_SCHEMA. USE CONNECTION stays with the admins.
resource "databricks_grants" "tools" {
  schema = "${databricks_catalog.ops_demo.name}.${databricks_schema.tools.name}"
  grant {
    principal  = local.users
    privileges = ["USE_SCHEMA"]
  }
  grant {
    principal  = local.assets
    privileges = ["USE_SCHEMA"]
  }
}

# ---------- Serverless SQL warehouse for Genie ----------

resource "databricks_sql_endpoint" "genie" {
  name                      = "png-demo-serverless"
  cluster_size              = "2X-Small"
  min_num_clusters          = 1
  max_num_clusters          = 1
  auto_stop_mins            = 10
  enable_serverless_compute = true
  warehouse_type            = "PRO"
}

resource "databricks_permissions" "warehouse" {
  sql_endpoint_id = databricks_sql_endpoint.genie.id
  access_control {
    group_name       = local.users
    permission_level = "CAN_USE"
  }
  access_control {
    group_name       = local.assets
    permission_level = "CAN_USE"
  }
  access_control {
    group_name       = local.admins
    permission_level = "CAN_MANAGE"
  }
}

output "catalog" {
  value = databricks_catalog.ops_demo.name
}

output "warehouse_id" {
  value = databricks_sql_endpoint.genie.id
}
