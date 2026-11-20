# Remote Azure MCP Server on Azure Container Apps, secured with Entra ID.
# Terraform version of https://github.com/Azure-Samples/azmcp-foundry-aca-mi, with these differences:
#   - write tools are enabled (no --read-only); Azure RBAC on the server's managed identity limits what it can do
#   - only identities explicitly assigned to the Entra app can call the server
#   - Azure CLI and VS Code are pre-authorized so the endpoint can be tested before Foundry is set up

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  # Subscription comes from ARM_SUBSCRIPTION_ID (set by scripts/04-setup-remote-mcp.sh).
  features {}
}

provider "azuread" {}

variable "azure_mcp_image" {
  type    = string
  default = "mcr.microsoft.com/azure-sdk/azure-mcp:3.0.0" # same version as Track 1
}

variable "min_replicas" {
  description = "1 keeps the server warm for demos; 0 scales to zero when idle (first call is slower)"
  type        = number
  default     = 1
}

# Outputs of infra/data (resource group, App Configuration store, web app).
data "terraform_remote_state" "data" {
  backend = "local"
  config = {
    path = "${path.module}/../data/terraform.tfstate"
  }
}

data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}

data "azurerm_resource_group" "rg" {
  name = data.terraform_remote_state.data.outputs.resource_group_name
}

locals {
  suffix    = substr(sha1(data.azurerm_resource_group.rg.id), 0, 8)
  appconfig = data.terraform_remote_state.data.outputs.app_configuration_id
  web_app   = data.terraform_remote_state.data.outputs.web_app_id

  namespaces = ["group", "storage", "role", "appconfig", "appservice"]

  # Well-known first-party client IDs allowed to request the delegated scope without a consent prompt.
  azure_cli_client_id = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
  vscode_client_id    = "aebc6443-996d-45c2-90f0-388ff96faa56"
}

# ---------------------------------------------------------------------------
# Entra app registration: defines who is allowed to call the MCP server
# ---------------------------------------------------------------------------

resource "random_uuid" "app_role" {}
resource "random_uuid" "scope" {}

resource "azuread_application" "mcp" {
  display_name = "azure-mcp-demo-server"
  owners       = [data.azuread_client_config.current.object_id]

  # Application permission: used by the Foundry project's managed identity (Phase 5).
  app_role {
    id                   = random_uuid.app_role.result
    value                = "Mcp.Tools.ReadWrite.All"
    display_name         = "Azure MCP Tools ReadWrite All"
    description          = "Application permission for Azure MCP tool calls"
    allowed_member_types = ["Application"]
    enabled              = true
  }

  # Delegated permission: used by signed-in users (Azure CLI smoke test, VS Code).
  api {
    requested_access_token_version = 2
    oauth2_permission_scope {
      id                         = random_uuid.scope.result
      value                      = "Mcp.Tools.ReadWrite"
      type                       = "User"
      admin_consent_display_name = "Azure MCP Tools ReadWrite"
      admin_consent_description  = "Delegated permission for Azure MCP tool calls"
      user_consent_display_name  = "Azure MCP Tools ReadWrite"
      user_consent_description   = "Delegated permission for Azure MCP tool calls"
      enabled                    = true
    }
  }

  lifecycle {
    ignore_changes = [identifier_uris] # managed by azuread_application_identifier_uri
  }
}

resource "azuread_application_identifier_uri" "mcp" {
  application_id = azuread_application.mcp.id
  identifier_uri = "api://${azuread_application.mcp.client_id}"
}

resource "azuread_application_pre_authorized" "clients" {
  for_each             = { azure_cli = local.azure_cli_client_id, vscode = local.vscode_client_id }
  application_id       = azuread_application.mcp.id
  authorized_client_id = each.value
  permission_ids       = [random_uuid.scope.result]
}

resource "azuread_service_principal" "mcp" {
  client_id = azuread_application.mcp.client_id
  owners    = [data.azuread_client_config.current.object_id]

  # Only identities assigned to this app can get a token for it.
  app_role_assignment_required = true
}

# Lets the signed-in user call the server (default access role, delegated scope).
resource "azuread_app_role_assignment" "me" {
  app_role_id         = "00000000-0000-0000-0000-000000000000"
  principal_object_id = data.azuread_client_config.current.object_id
  resource_object_id  = azuread_service_principal.mcp.object_id
}

# ---------------------------------------------------------------------------
# Container App running Azure MCP Server over HTTP
# ---------------------------------------------------------------------------

resource "azurerm_container_app_environment" "mcp" {
  name                = "cae-mcpdemo-${local.suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location

  # Azure adds this profile to new environments; declared here so plans stay clean.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app" "mcp" {
  name                         = "ca-azmcp-${local.suffix}"
  resource_group_name          = data.azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.mcp.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type = "SystemAssigned"
  }

  ingress {
    external_enabled           = true
    target_port                = 8080
    transport                  = "http"
    allow_insecure_connections = false # HTTPS only from outside
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 3

    container {
      name   = "azure-mcp"
      image  = var.azure_mcp_image
      cpu    = 0.25
      memory = "0.5Gi"

      # Never add --dangerously-disable-http-incoming-auth: it would let anyone use the managed identity.
      # --dangerously-disable-elicitation: over HTTP the server is stateless and can't ask the client to
      # confirm destructive or secret tools (kv set, app settings read/update, restart), so it would
      # reject them all. Confirmation moves to the client instead: the Foundry agent requires human
      # approval for these tools (Phase 5). Entra app assignment and RBAC still limit what can be done.
      args = concat(
        ["--transport", "http", "--outgoing-auth-strategy", "UseHostingEnvironmentIdentity", "--mode", "all",
        "--dangerously-disable-elicitation"],
        flatten([for ns in local.namespaces : ["--namespace", ns]])
      )

      env {
        name  = "ASPNETCORE_ENVIRONMENT"
        value = "Production"
      }
      env {
        name  = "ASPNETCORE_URLS"
        value = "http://+:8080"
      }
      # Outgoing calls to Azure use the container app's managed identity.
      env {
        name  = "AZURE_TOKEN_CREDENTIALS"
        value = "managedidentitycredential"
      }
      env {
        name  = "AZURE_MCP_INCLUDE_PRODUCTION_CREDENTIALS"
        value = "true"
      }
      env {
        name  = "AZURE_SUBSCRIPTION_ID"
        value = data.azurerm_client_config.current.subscription_id
      }
      # Incoming requests must carry an Entra token for this app.
      env {
        name  = "AzureAd__Instance"
        value = "https://login.microsoftonline.com/"
      }
      env {
        name  = "AzureAd__TenantId"
        value = data.azuread_client_config.current.tenant_id
      }
      env {
        name  = "AzureAd__ClientId"
        value = azuread_application.mcp.client_id
      }
      # Container Apps terminates TLS at ingress and forwards plain HTTP inside the pod.
      env {
        name  = "AZURE_MCP_DANGEROUSLY_DISABLE_HTTPS_REDIRECTION"
        value = "true"
      }
      # Advertise https URLs in OAuth metadata behind the TLS-terminating proxy (needed by VS Code).
      env {
        name  = "AZURE_MCP_DANGEROUSLY_ENABLE_FORWARDED_HEADERS"
        value = "true"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# What the server's managed identity may do in Azure (least privilege)
# ---------------------------------------------------------------------------

# Read everything in the resource group (resources, settings, role assignments). No writes.
resource "azurerm_role_assignment" "mcp_reader" {
  scope                = data.azurerm_resource_group.rg.id
  role_definition_name = "Reader"
  principal_id         = azurerm_container_app.mcp.identity[0].principal_id
}

# Read, write and lock key-values in the App Configuration store only.
resource "azurerm_role_assignment" "mcp_appconfig" {
  scope                = local.appconfig
  role_definition_name = "App Configuration Data Owner"
  principal_id         = azurerm_container_app.mcp.identity[0].principal_id
}

# Change app settings and start/stop/restart the web app. Cannot delete it or change anything else.
resource "azurerm_role_definition" "webapp_operator" {
  name        = "MCP Demo Web App Operator (${data.azurerm_resource_group.rg.name})"
  scope       = data.azurerm_resource_group.rg.id
  description = "Read and update app settings, and start/stop/restart web apps."

  permissions {
    actions = [
      "Microsoft.Web/sites/read",
      "Microsoft.Web/sites/config/read",
      "Microsoft.Web/sites/config/list/action",
      "Microsoft.Web/sites/config/write",
      "Microsoft.Web/sites/restart/action",
      "Microsoft.Web/sites/start/action",
      "Microsoft.Web/sites/stop/action",
    ]
  }

  assignable_scopes = [data.azurerm_resource_group.rg.id]
}

resource "azurerm_role_assignment" "mcp_webapp" {
  scope              = local.web_app
  role_definition_id = azurerm_role_definition.webapp_operator.role_definition_resource_id
  principal_id       = azurerm_container_app.mcp.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Outputs (Phase 5 connects the Foundry agent with these)
# ---------------------------------------------------------------------------

output "mcp_server_url" {
  value = "https://${azurerm_container_app.mcp.ingress[0].fqdn}"
}

output "entra_app_client_id" {
  value = azuread_application.mcp.client_id
}

output "entra_app_identifier_uri" {
  value = azuread_application_identifier_uri.mcp.identifier_uri
}

output "entra_app_role_id" {
  value = random_uuid.app_role.result
}

output "entra_app_service_principal_object_id" {
  value = azuread_service_principal.mcp.object_id
}

output "mcp_identity_principal_id" {
  value = azurerm_container_app.mcp.identity[0].principal_id
}
