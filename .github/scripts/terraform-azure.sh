#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
if [[ "$mode" != "plan" && "$mode" != "apply" && "$mode" != "destroy-plan" && "$mode" != "destroy" ]]; then
  echo "::error::Usage: terraform-azure.sh plan|apply|destroy-plan|destroy"
  exit 2
fi

for name in ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_TENANT_ID ARM_SUBSCRIPTION_ID; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Missing required repository secret for $name"
    exit 1
  fi
done

if [[ -z "${OPERATOR_IPS:-}" ]]; then
  echo "::error::Create the OPERATOR_IPS repository variable as a JSON array of authorized IPv4 CIDRs"
  exit 1
fi

az login --service-principal \
  --username "$ARM_CLIENT_ID" \
  --password "$ARM_CLIENT_SECRET" \
  --tenant "$ARM_TENANT_ID" \
  --output none
az account set --subscription "$ARM_SUBSCRIPTION_ID"

runner_ip="$(curl --fail --silent --show-error https://api.ipify.org)"
firewall_inputs="$(
  python3 - "$runner_ip" "$OPERATOR_IPS" <<'PY'
import ipaddress
import json
import sys
import urllib.request

runner = ipaddress.ip_address(sys.argv[1])
if runner.version != 4:
    raise SystemExit("GitHub runner egress address must be IPv4")

operator_ips = json.loads(sys.argv[2])
if not isinstance(operator_ips, list) or not operator_ips:
    raise SystemExit("OPERATOR_IPS must be a non-empty JSON array")

operator_networks = []
for value in operator_ips:
    network = ipaddress.ip_network(value, strict=False)
    if network.version != 4:
        raise SystemExit("OPERATOR_IPS must contain only IPv4 addresses/CIDRs")
    operator_networks.append(str(network))

with urllib.request.urlopen("https://api.github.com/meta", timeout=30) as response:
    actions_ranges = json.load(response)["actions"]
networks = [
    ipaddress.ip_network(value)
    for value in actions_ranges
    if ":" not in value
]
if not any(runner in network for network in networks):
    raise SystemExit(
        "Current runner IP is not in GitHub's published Actions IPv4 ranges; refusing firewall changes"
    )

rules = sorted(set(operator_networks + [f"{runner}/32"]))
if len(rules) > 400:
    raise SystemExit("OPERATOR_IPS plus runner address exceeds Azure's 400 IP-rule limit")
print(json.dumps(rules, separators=(",", ":")))
PY
)"
export TF_VAR_my_ip="$firewall_inputs"
export TF_VAR_alert_email="${ALERT_EMAIL:-}"

ssh_key="$RUNNER_TEMP/caribeshop_deploy_key"
ssh-keygen -q -t ed25519 -N "" -f "$ssh_key"
export TF_VAR_ssh_public_key_path="$ssh_key.pub"

state_rg="rg-tfstate"
state_account="statefordgarzautb"
state_rule_added=false
vault_rule_added=false
vault_name=""
vault_rg=""

cleanup() {
  result=$?
  if [[ "$mode" == "plan" || "$mode" == "destroy-plan" || $result -ne 0 ]]; then
    if [[ "$vault_rule_added" == true ]]; then
      az keyvault network-rule remove \
        --resource-group "$vault_rg" \
        --name "$vault_name" \
        --ip-address "$runner_ip" \
        --only-show-errors || echo "::warning::Could not remove the temporary Key Vault firewall rule"
    fi
  fi
  if [[ "$state_rule_added" == true ]]; then
    az storage account network-rule remove \
      --resource-group "$state_rg" \
      --account-name "$state_account" \
      --ip-address "$runner_ip" \
      --only-show-errors || echo "::warning::Could not remove the temporary state Storage firewall rule"
  fi
  exit "$result"
}
trap cleanup EXIT

state_rule_count="$(
  az storage account show \
    --resource-group "$state_rg" \
    --name "$state_account" \
    --query "networkRuleSet.ipRules[?ipAddressOrRange=='$runner_ip'] | length(@)" \
    --output tsv
)"
if [[ "$state_rule_count" == "0" ]]; then
  az storage account network-rule add \
    --resource-group "$state_rg" \
    --account-name "$state_account" \
    --ip-address "$runner_ip" \
    --only-show-errors
  state_rule_added=true
fi

terraform init -input=false

if terraform state list 2>/dev/null | grep -Fxq 'azurerm_key_vault.kv'; then
  vault_name="$(terraform state show -no-color azurerm_key_vault.kv | awk -F'"' '/^[[:space:]]*name = / { print $2; exit }')"
  vault_rg="$(terraform state show -no-color azurerm_resource_group.rg | awk -F'"' '/^[[:space:]]*name = / { print $2; exit }')"
  if [[ -z "$vault_name" || -z "$vault_rg" ]]; then
    echo "::error::Could not read the Key Vault and resource group names from Terraform state"
    exit 1
  fi
  vault_rule_count="$(
    az keyvault show \
      --resource-group "$vault_rg" \
      --name "$vault_name" \
      --query "properties.networkAcls.ipRules[?value=='$runner_ip'] | length(@)" \
      --output tsv
  )"
  if [[ "$vault_rule_count" == "0" ]]; then
    az keyvault network-rule add \
      --resource-group "$vault_rg" \
      --name "$vault_name" \
      --ip-address "$runner_ip" \
      --only-show-errors
    vault_rule_added=true
  fi
fi

case "$mode" in
  plan)
    terraform plan -input=false -no-color -lock-timeout=5m
    ;;
  apply)
    plan_file="$RUNNER_TEMP/caribeshop.tfplan"
    terraform plan -input=false -no-color -lock-timeout=5m -out="$plan_file"
    terraform apply -input=false -auto-approve -lock-timeout=5m "$plan_file"
    ;;
  destroy-plan)
    terraform plan -destroy -input=false -no-color -lock-timeout=5m
    ;;
  destroy)
    plan_file="$RUNNER_TEMP/caribeshop-destroy.tfplan"
    terraform plan -destroy -input=false -no-color -lock-timeout=5m -out="$plan_file"
    terraform apply -input=false -auto-approve -lock-timeout=5m "$plan_file"
    ;;
esac
