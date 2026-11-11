#!/usr/bin/env bash
# Creates a per-user OAuth (U2M) HTTP connection in ops_demo.tools for every internal MCP server deployed by
# infra/azure (terraform output mcp_urls). Connection name: <app name without -mcp, dashes -> underscores>_conn,
# e.g. service-desk-mcp -> service_desk_conn.
# Uses the Connections API (credential_type OAUTH_U2M_MAPPING).
# The client secret is generated here and passed to the API via a pipe: never printed, never written to disk.
# Idempotent: existing connections are left alone (no new secret is created if nothing is missing).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/.state/entra.env"
source "$ROOT/.state/entra-obo.env"
PROFILE="${DATABRICKS_CONFIG_PROFILE:?set DATABRICKS_CONFIG_PROFILE to the workspace CLI profile}"
PARENT="schemas/ops_demo.tools"
# "connection_name:https://host" pairs from the deployed MCP apps (bash 3.2 compatible, no associative arrays)
SERVERS=$(terraform -chdir="$ROOT/infra/azure" output -json mcp_urls | jq -r 'to_entries[]
  | "\(.key | sub("-mcp$"; "") | gsub("-"; "_"))_conn:\(.value | sub("/mcp$"; ""))"')

missing=()
for pair in $SERVERS; do
  databricks connections get "ops_demo.tools.${pair%%:*}" -p "$PROFILE" >/dev/null 2>&1 || missing+=("$pair")
done
[[ ${#missing[@]} -eq 0 ]] && { echo "Connections already exist."; exit 0; }

secret=$(az ad app credential reset --id "$MCP_CLIENT_APP_ID" --append \
  --display-name "uc-connections-$(date +%Y%m%d)" --end-date "$(date -v+90d +%Y-%m-%d)" \
  --query password -o tsv)

for pair in "${missing[@]}"; do
  name=${pair%%:*}; host=${pair#*:}
  jq -n --arg name "$name" --arg parent "$PARENT" --arg host "$host" \
        --arg cid "$MCP_CLIENT_APP_ID" --arg secret "$secret" --arg scope "$MCP_OAUTH_SCOPE" \
        --arg authz "$MCP_AUTHORIZATION_ENDPOINT" --arg token "$MCP_TOKEN_ENDPOINT" '{
    name: $name, parent: $parent, connection_type: "HTTP",
    comment: "Internal MCP server via private network gateway; per-user OAuth with Entra ID",
    options: {host: $host, port: "443", base_path: "/mcp",
              client_id: $cid, client_secret: $secret, oauth_scope: $scope,
              authorization_endpoint: $authz, token_endpoint: $token,
              oauth_credential_exchange_method: "body_only"}}' \
  | databricks api post /api/2.1/unity-catalog/connections -p "$PROFILE" --json @/dev/stdin \
  | jq -c '{full_name, credential_type, state: .provisioning_info.state}'
done
unset secret

# The creator owns the connections (changing the owner of schema-level connections isn't supported yet).
# Nobody else gets USE CONNECTION: end users get EXECUTE on the MCP services (bundle).
