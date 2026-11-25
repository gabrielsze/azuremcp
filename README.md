# Azure MCP Server demo

Demo of the [Azure MCP Server](https://learn.microsoft.com/azure/developer/azure-mcp-server/) used three ways against the same small set of Azure resources:

| # | Example | MCP server runs | Who calls it | Azure sees | Guide |
|---|---|---|---|---|---|
| 1 | GitHub Copilot in VS Code | Locally (stdio) | Copilot | **You** (`az login`) | [demo/track1-vscode.md](demo/track1-vscode.md) |
| 2a | Foundry agent | Azure Container Apps | Foundry Agent Service | The MCP server's managed identity | [demo/track2-foundry.md](demo/track2-foundry.md) |
| 2b | Self-run Python agent | Azure Container Apps | Your Python code | The MCP server's managed identity | [demo/track2-foundry.md](demo/track2-foundry.md#bonus-the-same-agent-run-by-your-own-code) |

All three run the same use cases:

- **A. Explore:** what's deployed in `rg-azuremcp`?
- **B. Audit:** storage security settings and role assignments
- **C. Change:** set and lock App Configuration keys, change a web app setting
- **D. Guardrails:** a locked key returns 409; in examples 2a and 2b, creating a storage account returns 403 because the server's identity isn't allowed to

## How the remote server is secured

```
caller ──token for api://<mcp-app>──▶ Azure MCP Server (Container Apps) ──managed identity──▶ Azure (RBAC)
        checked by the server (401)                                     checked by Azure (403)
```

- **Who may call it:** an Entra app registration. Only assigned identities get a token: the Foundry project's managed identity (app role) and you (delegated scope, for testing).
- **What it may do:** its own managed identity has Reader on the resource group, App Configuration Data Owner on the store, and a custom role that can change web app settings and restart it. Nothing else.
- **Approvals:** the remote server can't ask for confirmation over HTTP, so the agents require a person to approve every change.

## Repository layout

```
infra/data/      Terraform: resource group, storage account, App Configuration, App Service web app
infra/mcp/       Terraform: Azure MCP Server on Container Apps, Entra app registration, RBAC
infra/foundry/   Terraform: Foundry resource, project, gpt-6.1-sol, MCP connection
agents/          foundry_agent.py (2a), local_agent.py (2b)
scripts/         numbered setup, reset and test scripts
demo/            demo guides with prompts and expected results
.vscode/mcp.json local Azure MCP Server for example 1
```

## Prerequisites

- Azure subscription with Owner (or Contributor + User Access Administrator), and permission to create Entra app registrations
- `az` (signed in with `az login`), `terraform` 1.6+, Node.js (for `npx`), Python 3.11+
- VS Code with GitHub Copilot (example 1)

## Setup

Run in order. Each step is a separate Terraform stack with local state.

```bash
./scripts/01-setup-infra.sh         # infra/data
./scripts/02-reset-demo.sh          # seed App Configuration and web app settings
python3 scripts/03-test-local-mcp.py   # check the local server (example 1)
./scripts/04-setup-remote-mcp.sh    # infra/mcp (the Container Apps environment can take ~20 min the first time)
python3 scripts/04-test-remote-mcp.py  # check auth, reads, writes and the 403
./scripts/05-setup-foundry.sh       # infra/foundry + Python venv
agents/.venv/bin/python agents/foundry_agent.py create
```

## Running the demos

```bash
# 1: open this folder in VS Code, start azure-mcp-demo (MCP: List Servers), use Copilot Chat in Agent mode

# 2a: Foundry agent (or use the agent in the Foundry portal playground)
agents/.venv/bin/python agents/foundry_agent.py demo   # step through A–D: Enter sends, or type your own
agents/.venv/bin/python agents/foundry_agent.py chat

# 2b: self-run agent; --verbose shows the token claims and each MCP request/response
agents/.venv/bin/python agents/local_agent.py demo --verbose
agents/.venv/bin/python agents/local_agent.py chat

# after any demo: unlock keys and restore starting values
./scripts/02-reset-demo.sh
```

## Teardown

Destroy in reverse order (each stack reads the outputs of the one before it):

```bash
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform -chdir=infra/foundry destroy
terraform -chdir=infra/mcp destroy      # also removes the Entra app registration
terraform -chdir=infra/data destroy
```

## Notes

- **Cost:** mostly the always-on MCP container (`min_replicas = 1`, roughly $10–20/month); set it to 0 to scale to zero at the cost of a slower first call. App Configuration and App Service are on free tiers; the model is pay per token.
- **Versions:** Azure MCP Server is pinned to 3.0.0 locally (`npx`) and remotely (container image).
- **Copilot speed:** turn off other MCP servers (for example the Azure MCP extension) for the demo chat, and unpin files.
- **Known tool gaps (3.0.0):** role assignments come back as IDs, not names; App Service diagnostics return empty results.
