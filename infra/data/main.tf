# Demo targets: resource group, storage account (to audit) and App Configuration (to change).
# Both demo tracks (VS Code Copilot and the Foundry agent) work against these via Azure MCP.

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  # Subscription comes from ARM_SUBSCRIPTION_ID (set by scripts/01-setup-data.sh).
  features {}
  storage_use_azuread = true # shared keys are disabled on the account
}

variable "resource_group_name" {
  type    = string
  default = "rg-azuremcp"
}

variable "location" {
  type    = string
  default = "eastus2"
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_storage_account" "demo" {
  name                            = "stmcpdemo${substr(sha1(azurerm_resource_group.rg.id), 0, 8)}"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # Entra ID only, no account keys
}

# Created through ARM (storage_account_id), so no data-plane access is needed here.
resource "azurerm_storage_container" "demo" {
  name               = "demo-data"
  storage_account_id = azurerm_storage_account.demo.id
}

# Lets the signed-in user upload the sample blobs.
resource "azurerm_role_assignment" "deployer_blob" {
  scope                = azurerm_storage_account.demo.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# App Configuration: the thing the agents will change (use cases C and D).
# Only the store is managed here. The key-values are seeded by scripts/02-seed-appconfig.sh
# because the agents change them at runtime, and Terraform would otherwise revert those changes.
resource "azurerm_app_configuration" "demo" {
  name                  = "appcs-mcpdemo-${substr(sha1(azurerm_resource_group.rg.id), 0, 8)}"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  sku                   = "free"
  local_auth_enabled    = false # Entra ID only, no access keys
  public_network_access = "Enabled"
}

# Lets the signed-in user read, write and lock key-values.
resource "azurerm_role_assignment" "deployer_appconfig" {
  scope                = azurerm_app_configuration.demo.id
  role_definition_name = "App Configuration Data Owner"
  principal_id         = data.azurerm_client_config.current.object_id
}

output "app_configuration_name" {
  value = azurerm_app_configuration.demo.name
}

output "app_configuration_endpoint" {
  value = azurerm_app_configuration.demo.endpoint
}

output "app_configuration_id" {
  value = azurerm_app_configuration.demo.id
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "storage_account_name" {
  value = azurerm_storage_account.demo.name
}

output "storage_account_id" {
  value = azurerm_storage_account.demo.id
}
