# Track 2: Azure MCP from a Foundry agent

A Foundry agent (`azure-ops-agent`, model `gpt-6.1-sol`) uses the **remote** Azure MCP Server on Container Apps.

```
Foundry agent ──(project managed identity token, role Mcp.Tools.ReadWrite.All)──▶ Azure MCP Server (Container Apps)
                                                                                        │
                                                   container app's managed identity ────┘──▶ rg-azuremcp (RBAC)
```

- **Who may call the MCP server:** the Foundry project's managed identity, through the Entra app role (`infra/foundry`).
- **What the server may do in Azure:** only what its own managed identity is allowed (`infra/mcp`): read the resource group, set and lock App Configuration keys, change web app settings and restart it. Nothing else.
- **Approvals:** the agent runs read tools freely. Every change tool needs a person to approve it. The remote server can't ask for confirmation itself (see `infra/mcp/main.tf`), so the approval in Foundry is the human check.

## Before the demo

1. `az login` to the subscription that holds `rg-azuremcp`.
2. Reset the demo state:
   ```bash
   ./scripts/02-reset-demo.sh
   ```
3. Check the MCP server, then the agent (read-only prompt, no changes):
   ```bash
   python3 scripts/04-test-remote-mcp.py
   printf "What's deployed in the resource group?\n\n" | agents/.venv/bin/python agents/foundry_agent.py chat
   ```
4. Open the Azure portal on the App Configuration store → **Configuration explorer**, and the web app → **Settings → Environment variables**.

## Running the demo

**Terminal (works today):**
```bash
agents/.venv/bin/python agents/foundry_agent.py demo     # scripted A–D, you approve each change with y/N
agents/.venv/bin/python agents/foundry_agent.py chat     # free-form chat with the same approvals
```

**Foundry portal:** open [ai.azure.com](https://ai.azure.com) → project `proj-mcpdemo` → agent `azure-ops-agent` → playground. Use the same prompts. If the playground shows the approval requests, demo there; otherwise use the terminal.

Each tool call is printed as `[tool] name(arguments) -> result`. Calls that need approval are printed as `[approval needed]` first.

## Demo script

### A. Explore

> What's deployed in the resource group?

`group_resource_list`, no approval. Lists 9 resources, including the MCP server's container app and the agent's own Foundry project.

### B. Audit

> Does the storage account allow public blob access, and is HTTPS-only traffic enforced? List the role assignments in the resource group.

`storage_account_get` and `role_assignment_list`, no approval. Public access off, HTTPS only on. The role list returns IDs, not names; the agent says so. One of the service principals is the MCP server's own identity.

### C. Change (approve each one)

> In App Configuration, set Checkout:NewUI to true and Checkout:MaxRetries to 5, then lock both keys because we're in a change freeze. Also set LOG_LEVEL to debug on the web app.

Five approval requests: `appconfig_kv_set` ×2, `appconfig_kv_lock_set` ×2, `appservice_webapp_settings_update-appsettings`. Try rejecting one to show the agent stops and reports it. Refresh the portal pages to show the changes.

### D1. Guardrail: the lock

> Change Checkout:MaxRetries to 10.

Approve it. App Configuration returns **409, key is read-only**, and the agent won't unlock it on its own.

Run this right after C in the same conversation. In a fresh chat the agent often reads the key first, sees the lock and doesn't try at all, which is also a fine outcome to show.

### D2. Guardrail: permissions

> Create a new storage account called stmcpdemoextra001 in eastus2 in the resource group.

Approve it. Azure returns **403 AuthorizationFailed**: the MCP server's identity has no `Microsoft.Storage/storageAccounts/write` permission. Talking point: **even an approved request can't exceed the identity's permissions.**

## After the demo

```bash
./scripts/02-reset-demo.sh
```

## Changing the agent

Edit the instructions, tools or approval lists in [agents/foundry_agent.py](../agents/foundry_agent.py), then create a new version:

```bash
agents/.venv/bin/python agents/foundry_agent.py create
```
