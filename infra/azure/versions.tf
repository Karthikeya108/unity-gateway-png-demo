terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Authenticates with the Azure CLI login (Entra ID OAuth). No secrets in config.
provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # Shared-key access is disabled on the storage account; use Entra ID for any data-plane call.
  storage_use_azuread = true

  # Least privilege: don't try to register every resource provider in the subscription.
  resource_provider_registrations = "none"

  features {
    resource_group {
      # Subscription policies may add resources to the RG (e.g. DNS security policies); let destroy remove them.
      prevent_deletion_if_contains_resources = false
    }
  }
}
