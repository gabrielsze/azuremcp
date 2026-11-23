# Track 2: Foundry resource, project and model, connected to the remote Azure MCP Server (infra/mcp).
# The project's managed identity gets the MCP server's app role, so agents in this project can CALL
# the server. It gets no Azure RBAC on the demo resources: the server acts with its own identity.

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  # Subscription comes from ARM_SUBSCRIPTION_ID (set by scripts/05-setup-foundry.sh).
  features {
    cognitive_account {
      purge_soft_delete_on_destroy = true # lets the same name be reused after teardown
    }
  }
}

provider "azuread" {}
provider "azapi" {}

variable "model_name" {
  type    = string
  default = "gpt-6.1-sol"
}

variable "model_version" {
  type    = string
  default = "2026-09-29"
}

variable "model_capacity" {
  description = "Thousands of tokens per minute (GlobalStandard)"
  type        = number
  default     = 50
}

data "terraform_remote_state" "data" {
  backend = "local"
  config = {
    path = "${path.module}/../data/terraform.tfstate"
  }
}

data "terraform_remote_state" "mcp" {
  backend = "local"
  config = {
    path = "${path.module}/../mcp/terraform.tfstate"
  }
}

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "rg" {
  name = data.terraform_remote_state.data.outputs.resource_group_name
}

locals {
  suffix = substr(sha1(data.azurerm_resource_group.rg.id), 0, 8)
  mcp    = data.terraform_remote_state.mcp.outputs
}

# ---------------------------------------------------------------------------
# Foundry resource, project and model
# ---------------------------------------------------------------------------

resource "azurerm_cognitive_account" "foundry" {
  name                       = "aif-mcpdemo-${local.suffix}"
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = data.azurerm_resource_group.rg.location
  kind                       = "AIServices"
  sku_name                   = "S0"
  custom_subdomain_name      = "aif-mcpdemo-${local.suffix}"
  project_management_enabled = true
  local_auth_enabled         = false # Entra ID only, no API keys

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_account_project" "demo" {
  name                 = "proj-mcpdemo"
  cognitive_account_id = azurerm_cognitive_account.foundry.id
  location             = azurerm_cognitive_account.foundry.location
  display_name         = "Azure MCP demo"

  # This identity calls the MCP server on behalf of every agent in the project.
  identity {
    type = "SystemAssigned"
  }

  # The account accepts one operation at a time; creating this alongside the model deployment returns 409.
  depends_on = [azurerm_cognitive_deployment.model]
}

resource "azurerm_cognitive_deployment" "model" {
  name                 = var.model_name
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = var.model_capacity
  }
}

# Lets the signed-in user create and run agents (data-plane). "Azure AI User", recently renamed "Foundry User".
resource "azurerm_role_assignment" "me_ai_user" {
  scope              = azurerm_cognitive_account.foundry.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/53ca6127-db72-4b80-b1b0-d745d6d5456d"
  principal_id       = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# Wiring the project to the MCP server
# ---------------------------------------------------------------------------

# Allows the project's managed identity to get a token for the MCP server (roles = Mcp.Tools.ReadWrite.All).
resource "azuread_app_role_assignment" "project_to_mcp" {
  app_role_id         = local.mcp.entra_app_role_id
  principal_object_id = azurerm_cognitive_account_project.demo.identity[0].principal_id
  resource_object_id  = local.mcp.entra_app_service_principal_object_id
}

# Project connection: where the MCP server is and how to authenticate (project managed identity + audience).
# Same body as `azd ai connection create --kind remote-tool --auth-type project-managed-identity`.
resource "azapi_resource" "mcp_connection" {
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name                      = "azure-mcp-demo"
  parent_id                 = azurerm_cognitive_account_project.demo.id
  schema_validation_enabled = false # `audience` isn't in the published schema yet

  body = {
    properties = {
      category = "RemoteTool"
      authType = "ProjectManagedIdentity"
      target   = local.mcp.mcp_server_url
      audience = local.mcp.entra_app_identifier_uri
    }
  }

  depends_on = [azuread_app_role_assignment.project_to_mcp]
}

# ---------------------------------------------------------------------------
# Outputs (used by agents/foundry_agent.py)
# ---------------------------------------------------------------------------

output "project_endpoint" {
  value = "https://${azurerm_cognitive_account.foundry.custom_subdomain_name}.services.ai.azure.com/api/projects/${azurerm_cognitive_account_project.demo.name}"
}

output "model_deployment_name" {
  value = azurerm_cognitive_deployment.model.name
}

output "mcp_connection_name" {
  value = azapi_resource.mcp_connection.name
}

output "mcp_connection_id" {
  value = azapi_resource.mcp_connection.id
}

output "mcp_server_url" {
  value = local.mcp.mcp_server_url
}

output "project_identity_principal_id" {
  value = azurerm_cognitive_account_project.demo.identity[0].principal_id
}
