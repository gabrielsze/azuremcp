#!/usr/bin/env bash
# Step 5: deploy Foundry (infra/foundry) and install the agent script's Python dependencies.
# Requires infra/data and infra/mcp to be applied first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

echo "==> terraform apply (infra/foundry) in subscription $ARM_SUBSCRIPTION_ID"
terraform -chdir="$ROOT/infra/foundry" init -input=false -upgrade >/dev/null
terraform -chdir="$ROOT/infra/foundry" apply -input=false -auto-approve

echo "==> Python environment for agents/"
[ -d "$ROOT/agents/.venv" ] || python3 -m venv "$ROOT/agents/.venv"
"$ROOT/agents/.venv/bin/pip" install -q -r "$ROOT/agents/requirements.txt"
