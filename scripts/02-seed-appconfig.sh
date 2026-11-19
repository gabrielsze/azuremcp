#!/usr/bin/env bash
# Step 2: seed (or reset) the App Configuration key-values used in the demo.
# Safe to rerun before each demo: it unlocks the keys and restores the starting values.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENDPOINT=$(terraform -chdir="$ROOT/infra/data" output -raw app_configuration_endpoint)

KEYS=("Checkout:NewUI=false" "Checkout:MaxRetries=3" "Banner:Message=Welcome to the demo store")

# New data-plane role assignments can take a minute or two to propagate.
echo "==> Waiting for data-plane access to $ENDPOINT"
for i in {1..12}; do
  if az appconfig kv list --endpoint "$ENDPOINT" --auth-mode login -o none 2>/dev/null; then
    echo "    ok"; break
  fi
  [[ $i == 12 ]] && { echo "    still no access, rerun in a minute"; exit 1; }
  echo "    waiting for RBAC... ($i/12)"; sleep 15
done

echo "==> Seeding key-values"
for kv in "${KEYS[@]}"; do
  key="${kv%%=*}"; value="${kv#*=}"
  # A previous demo run may have locked the key.
  az appconfig kv unlock --endpoint "$ENDPOINT" --auth-mode login --key "$key" --yes -o none 2>/dev/null || true
  az appconfig kv set --endpoint "$ENDPOINT" --auth-mode login --key "$key" --value "$value" --yes -o none
  echo "    $key = $value"
done

az appconfig kv list --endpoint "$ENDPOINT" --auth-mode login \
  --query "[].{key:key, value:value, locked:locked}" -o table 2>/dev/null
