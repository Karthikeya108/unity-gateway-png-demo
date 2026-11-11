# Unity Gateway + Private Network Gateway demo (Azure)

A Databricks App and agents on **serverless compute** use internal tools **on behalf of the signed-in user**, while
the lakehouse data stays in your own firewalled storage. One **network connectivity configuration (NCC)** gives
serverless both private paths:

| Path | NCC feature | Used for |
|---|---|---|
| Serverless → ADLS | Private endpoint rules (Private Link) | Delta tables in the catalog's managed location in your storage account |
| Serverless → your VNet | **Private network gateway** | Internal MCP servers on Azure Container Apps (internal only) |

Identity is **Microsoft Entra ID + OAuth end to end**: users sign in with Entra, the app uses user authorization, and
Unity Gateway calls the MCP servers with each user's own Entra token.

```
 Databricks App (user authorization)
   ├─ Genie ─────────── serverless SQL ── NCC private endpoints ──► ADLS (network Deny): Delta tables
   └─ Unity Gateway MCP services (per-user OAuth)
          └─ serverless ── NCC private network gateway ──► hub VNet ─peering─► spoke VNet
                                                                           └─ Container Apps (internal)
                                                                                ├─ service-desk-mcp
                                                                                └─ asset-inventory-mcp
```

More detail:
- [docs/guide.md](docs/guide.md): architecture, components, personas, permissions, verification, adding services,
  reset and teardown.
- [docs/identity.md](docs/identity.md): the identity design, and how to use a different identity provider.

## What you need

- An Azure Databricks **Premium** workspace with Unity Catalog and serverless compute, in a region where the
  [private network gateway](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/private-network-gateway/configure-private-network-gateway#requirements)
  is available, with the feature enabled for your account.
- **Databricks:** account admin (NCC, gateway, groups) and metastore admin (storage credential, catalog), or the
  equivalent `CREATE` privileges.
- **Entra ID:** rights to register applications (no admin consent needed).
- **Azure:** Contributor on the subscription, plus the right to create two role assignments, each scoped to a single
  resource.
- **Tools:** Azure CLI, Databricks CLI ≥ 1.17, Terraform ≥ 1.6, `jq`, Python 3.
- **Sign-in with OAuth:** `az login --tenant <tenant>`, and `databricks auth login` for a workspace profile and an
  account profile.

Your settings go into git-ignored files: `infra/*/terraform.tfvars` (copy the `*.example` files),
`bundle/.databricks/bundle/dev/variable-overrides.json` (copy `bundle/variable-overrides.json.example`) and `.state/`
(written by the scripts; IDs only, no secrets).

## Deploy

```bash
export TENANT_ID=<entra tenant id>
export WORKSPACE_HOST=https://adb-<id>.<n>.azuredatabricks.net
export DATABRICKS_CONFIG_PROFILE=<workspace profile>

# 1. Entra app registrations
./scripts/01-entra-apps.sh && ./scripts/02-entra-obo.sh

# 2. Azure infrastructure (first without the MCP apps; the image doesn't exist yet)
cp infra/azure/terraform.tfvars.example infra/azure/terraform.tfvars   # fill in, incl. app IDs from .state/entra.env
terraform -chdir=infra/azure init
terraform -chdir=infra/azure apply -var deploy_mcp_apps=false

# 3. MCP image and container apps
PIP_INDEX_URL=<optional private index> ./scripts/03-build-mcp-image.sh v1
terraform -chdir=infra/azure apply

# 4. Databricks account: groups, NCC, private endpoint rules, private network gateway
cp infra/databricks-account/terraform.tfvars.example infra/databricks-account/terraform.tfvars   # fill in
terraform -chdir=infra/databricks-account init && terraform -chdir=infra/databricks-account apply
SA=$(terraform -chdir=infra/azure output -raw storage_account_id)            # approve the private endpoints
for id in $(az network private-endpoint-connection list --id "$SA" \
    --query "[?properties.privateLinkServiceConnectionState.status=='Pending'].id" -o tsv); do
  az network private-endpoint-connection approve --id "$id" --description "Databricks NCC"
done

# 5. Unity Catalog
cp infra/databricks-workspace/terraform.tfvars.example infra/databricks-workspace/terraform.tfvars
terraform -chdir=infra/databricks-workspace init && terraform -chdir=infra/databricks-workspace apply

# 6. Connections, Genie space, bundle (data job, connectivity check, MCP services, app)
./scripts/04-create-mcp-connections.sh
./scripts/05-create-genie-space.sh
cp bundle/variable-overrides.json.example bundle/.databricks/bundle/dev/variable-overrides.json   # fill in
(cd bundle && databricks bundle deploy \
   && databricks bundle run generate_ops_data \
   && databricks bundle run connectivity_check \
   && databricks bundle run ops_assistant)
```

Finally, **each demo user signs in once per MCP service**: Unity Gateway → MCPs → `service_desk` /
`asset_inventory` → *Login*. Then open the app and ask, for example, *"Which sites had the worst SLA performance last
quarter, and which high-priority requests are open there?"*

To check each private path, reset the demo data, or tear everything down, see [docs/guide.md](docs/guide.md).

## Disclaimer

This repository is provided as a starting point for learning and demonstration purposes only. It is not intended for
production use and may require additional hardening, testing and review before being used in any production
environment. The code is provided "as is", without warranty or support of any kind, express or implied, and you use
it at your own risk.

Parts of this repository were generated with the assistance of AI tools.
