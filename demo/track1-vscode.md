# Track 1: Azure MCP in VS Code with GitHub Copilot

The Azure MCP Server runs **locally** (stdio, started by VS Code from [.vscode/mcp.json](../.vscode/mcp.json)) and acts as **you**, using your `az login` account.

## Before the demo

1. Sign in to the subscription that holds `rg-azuremcp`:
   ```bash
   az login
   az account set --subscription <subscription-id>
   ```
2. Reset the demo state (unlocks keys, restores starting values):
   ```bash
   ./scripts/02-reset-demo.sh
   ```
3. Check the server starts and can see the resource group:
   ```bash
   python3 scripts/03-test-local-mcp.py
   ```
4. In VS Code, open this folder, run **MCP: List Servers** → `azure-mcp-demo` → **Start**, and trust it when prompted.
5. Open Copilot Chat in **Agent** mode. In the tools picker, make sure `azure-mcp-demo` is enabled. If the Azure MCP VS Code extension is also installed, turn its server off for the demo so Copilot doesn't see two copies of every tool.
6. Open the Azure portal on the App Configuration store → **Configuration explorer**, and the web app → **Environment variables**. These are where you show changes landing.

## Demo script

Copilot asks for confirmation before each tool call. Expand the call to show the audience the exact command and parameters.

### A. Explore: what's deployed?

> What's deployed in the resource group rg-azuremcp?

Expect: `group_resource_list`. It lists the storage account, App Configuration store, App Service plan, web app, and an Event Grid system topic Azure created for the storage account.

### B. Audit: is it configured safely?

> Audit rg-azuremcp: does the storage account allow public blob access, and is HTTPS-only traffic enforced? List the role assignments in the resource group and which roles they grant.

Expect: `storage_account_get` (public blob access off, HTTPS only on) and `role_assignment_list`. The role tool returns principal and role-definition IDs, not names, and only assignments made at the resource group or below. Copilot usually recognises built-in role IDs (for example `ba92f5b4…` is Storage Blob Data Contributor). Subscription-level roles such as your Owner assignment don't appear.

Stick to fields the tools return. If you ask about something they don't return (for example shared-key access or the web app's HTTPS-only flag), Copilot may answer from general knowledge instead of from Azure.

> Skipped on purpose: App Service diagnostics (`appservice_webapp_diagnostic_diagnose`). In Azure MCP 3.0.0 the detector runs, but every result table comes back `null`, even though the same detector returns data through the REST API. Copilot then reports "no issues", which is misleading in a demo.

### C. Change: a controlled config change

> In the App Configuration store, set Checkout:NewUI to true and Checkout:MaxRetries to 5, then lock both keys because we're in a change freeze.

Expect: `appconfig_kv_set` ×2, `appconfig_kv_lock_set` ×2. Refresh Configuration explorer: new values, both locked.

> On the web app, set LOG_LEVEL to debug and restart it.

Expect: `appservice_webapp_settings_update-appsettings`, `appservice_webapp_change-state` (restart). Refresh Environment variables in the portal.

### D. Guardrail: the lock still applies

> Change Checkout:MaxRetries to 10.

Expect: `appconfig_kv_set` fails with **409 – the key is read-only, unlock it first**. Copilot explains and asks whether to unlock. Say no.

Talking point: in this track the server acts as you (Owner), so only the lock stops the change. In Track 2 the agent's managed identity also lacks permission to delete or reconfigure resources.

## After the demo

```bash
./scripts/02-reset-demo.sh
```
