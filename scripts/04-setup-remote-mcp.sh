#!/usr/bin/env bash
# Step 4: deploy the remote Azure MCP Server (infra/mcp). Requires infra/data to be applied first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

# infra/mcp reads infra/data outputs (e.g. web_app_id), so refresh them first.
terraform -chdir="$ROOT/infra/data" apply -input=false -auto-approve -refresh-only >/dev/null

echo "==> terraform apply (infra/mcp) in subscription $ARM_SUBSCRIPTION_ID"
terraform -chdir="$ROOT/infra/mcp" init -input=false -upgrade >/dev/null
terraform -chdir="$ROOT/infra/mcp" apply -input=false -auto-approve
