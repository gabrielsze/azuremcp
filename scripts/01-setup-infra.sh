#!/usr/bin/env bash
# Step 1: terraform apply infra/data -> resource group + storage account the demos will query.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/infra/data"
export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

echo "==> terraform apply ($TF_DIR) in subscription $ARM_SUBSCRIPTION_ID"
terraform -chdir="$TF_DIR" init -input=false -upgrade >/dev/null
terraform -chdir="$TF_DIR" apply -input=false -auto-approve
