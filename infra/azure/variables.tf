variable "subscription_id" {
  description = "Azure subscription for all demo resources."
  type        = string
}

variable "tenant_id" {
  description = "Entra ID tenant of the subscription and the Databricks workspace (PNG requires the same tenant)."
  type        = string
}

variable "location" {
  type    = string
  default = "northeurope"
}

variable "prefix" {
  description = "Short prefix for resource names."
  type        = string
  default     = "pngdemo"
}

variable "hub_address_space" {
  type    = string
  default = "10.60.0.0/22"
}

variable "png_subnet_prefix" {
  description = "Dedicated subnet for the private network gateway (/28 or larger)."
  type        = string
  default     = "10.60.0.0/28"
}

variable "spoke_address_space" {
  type    = string
  default = "10.61.0.0/22"
}

variable "aca_subnet_prefix" {
  description = "Container Apps environment subnet (/27 or larger for workload profiles)."
  type        = string
  default     = "10.61.0.0/27"
}

variable "owner" {
  description = "Value of the 'owner' tag (many subscriptions enforce it by policy)."
  type        = string
}

variable "tags" {
  type = map(string)
  default = {
    project = "png-mcp-demo"
    purpose = "demo"
  }
}

locals {
  tags = merge(var.tags, { owner = var.owner })
}
