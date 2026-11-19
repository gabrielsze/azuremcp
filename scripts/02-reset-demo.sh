#!/usr/bin/env bash
# Step 2: seed (or reset) the demo state. Safe to rerun before each demo.
#   - App Configuration: unlocks the keys and restores the starting values
#   - App Service: restores the starting app settings
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="terraform -chdir=$ROOT/infra/data"
ENDPOINT=$($TF output -raw app_configuration_endpoint)
RG=$($TF output -raw resource_group_name)
WEBAPP=$($TF output -raw web_app_name)

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

echo "==> Resetting app settings on $WEBAPP"
az webapp config appsettings set -g "$RG" -n "$WEBAPP" \
  --settings LOG_LEVEL=info FEATURE_NEW_CHECKOUT=false \
  --query "[?name=='LOG_LEVEL' || name=='FEATURE_NEW_CHECKOUT'].{name:name, value:value}" -o table
