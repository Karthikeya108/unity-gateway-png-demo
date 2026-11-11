# Demo guide: architecture, operations and extension

Details behind the [README](../README.md): how the demo is built, who gets which permissions, how to check that each
private path works, and how to add more internal services. For the identity design, see [identity.md](identity.md).

## Architecture

```
 Databricks serverless (Databricks-managed)               Your Azure subscription (same Entra tenant)
 ┌───────────────────────────────────────────┐            ┌──────────────────────────────────────────────────────────┐
 │ Databricks App "Operations Assistant"     │            │ ADLS Gen2 (HNS), network default: Deny                   │
 │  (user authorization)                     │            │   ├─ private endpoints (dfs, blob) ◄── NCC PE rules      │
 │   └─> Agent (Foundation Model API)        │            │   └─ resource-instance rule: Access Connector            │
 │        ├─> Genie space ───────────────────┼──PL───────►│   container "ops-demo" = catalog managed location        │
 │        │     serverless SQL warehouse     │            │                                                          │
 │        └─> Unity Gateway (MCP services)   │            │ hub-vnet                                                 │
 │              ├─ service_desk              │            │   snet-png /28, delegated to Microsoft.Databricks/ws     │
 │              └─ asset_inventory ══════════╪══PNG══════►│   private DNS zone (Container Apps domain), linked       │
 │                                           │            │        │ VNet peering                                    │
 │ NCC                                       │            │ spoke-vnet                                               │
 │   ├─ private endpoint rules: dfs, blob    │            │   snet-aca /27, Container Apps environment (internal)    │
 │   └─ private network gateway              │            │        ├─ service-desk-mcp     (FastMCP)                 │
 │        SPECIFIC_DESTINATIONS: <env domain>│            │        └─ asset-inventory-mcp  (FastMCP)                 │
 └───────────────────────────────────────────┘            └──────────────────────────────────────────────────────────┘
```

Routing order for serverless traffic: private endpoint rules first, then the private network gateway, then default
egress.

## Components

| Layer | Resource | Notes |
|---|---|---|
| Azure storage | ADLS Gen2 `<prefix>opsdemo`, container `ops-demo` | Public network default **Deny**, no IP rules, resource-instance rule for the Access Connector, shared-key access disabled |
| Azure identity | Databricks Access Connector (system-assigned managed identity) | `Storage Blob Data Contributor` on this storage account only |
| Azure network | `hub-vnet` + `snet-png` (/28, delegated) | Dedicated to the private network gateway |
| Azure network | `spoke-vnet` + `snet-aca` (/27), peered to the hub | Internal "tools" network |
| Azure compute | Container Apps environment, **internal** ingress | Hosts both MCP servers; no public IP |
| Azure DNS | Private DNS zone for the Container Apps domain, linked to `hub-vnet` | Azure-provided DNS |
| Entra ID | `png-demo-mcp-api` (delegated scope `MCP.Access`, app role `ServiceDesk.Agent`), `png-demo-mcp-client` (OAuth client of the connections, pre-authorised on the API) | Per-user OAuth: the MCP servers receive the user's own Entra token |
| Databricks account | NCC with private endpoint rules (`dfs`, `blob`) and the private network gateway (`SPECIFIC_DESTINATIONS`) | Attached to the demo workspace |
| Unity Catalog | Storage credential → external location → catalog `ops_demo` with a **managed location** in your storage | Delta tables are managed tables in your container |
| Unity Catalog | Per-user OAuth HTTP connections + MCP services `service_desk`, `asset_inventory` | Registered in Unity Gateway; each user signs in once per service |
| Genie | Space over `ops_demo.lakehouse.*` | Runs on a serverless SQL warehouse, which reaches storage over Private Link |
| Databricks App | "Operations Assistant" (FastAPI + web UI), user authorization | The agent combines Genie (history) with the MCP services (live systems) |
| Groups | Account groups `png-demo-admins`, `png-demo-users`, `png-demo-assets-only` | Least-privilege grants |

### MCP servers (Python FastMCP, streamable HTTP, seeded SQLite)

| Server | Tools |
|---|---|
| `service-desk-mcp` | `search_requests`, `get_request`, `create_request`, `update_request_status` |
| `asset-inventory-mcp` | `get_asset`, `search_assets`, `get_asset_history` |

Both servers act on behalf of the calling user: `create_request` records the real requester, `mine=true` returns only
the caller's requests, and `update_request_status` requires the app role `ServiceDesk.Agent`. Every call is logged
with user and client (never the token).

### Delta tables (`ops_demo.lakehouse`)

| Table | Content |
|---|---|
| `sites` | Site reference (id, name, country, region) |
| `assets_dim` | Asset master snapshot (id, type, site, install date, warranty end) |
| `request_history` | About 18 months of closed requests (category, priority, site, asset, opened/closed, SLA met) |
| `asset_daily_metrics` | Daily uptime % and incident count per asset (12 months) |

The IDs match the MCP seed data, so the agent can join live data (MCP) with history (Delta). The data is generated by
a serverless job, which is also the first check that serverless writes to your storage over Private Link.

## Repository layout

| Path | What |
|---|---|
| `scripts/01-entra-apps.sh`, `02-entra-obo.sh` | Entra app registrations: API (scope `MCP.Access`, role `ServiceDesk.Agent`) and client (pre-authorised, redirect URI) |
| `infra/azure` | Terraform: VNets, delegated gateway subnet, internal Container Apps environment + private DNS, ADLS (Deny) + Access Connector, container registry, MCP container apps, storage request logs |
| `mcp/` | MCP servers (FastMCP, streamable HTTP) with Entra token validation; shared seed data (`seed_data.py`, copied to `bundle/src/` so the Delta history uses the same IDs; keep the copies identical) |
| `scripts/03-build-mcp-image.sh` | Builds the image in the container registry (wheels downloaded locally, installed offline) |
| `infra/databricks-account` | Terraform: account groups + workspace assignment, NCC, private endpoint rules, **private network gateway**, NCC binding |
| `infra/databricks-workspace` | Terraform: storage credential, external location, catalog with **managed location**, schemas, serverless warehouse, grants |
| `scripts/04-create-mcp-connections.sh` | Per-user OAuth (U2M) HTTP connections via the Connections API |
| `scripts/05-create-genie-space.sh` | Genie space over the Delta tables |
| `bundle/` | Declarative Automation Bundle: data job, connectivity check, **MCP services + grants**, the app |

## Personas

| Persona | Groups | Entra app role on `png-demo-mcp-api` | Shows |
|---|---|---|---|
| A: service-desk agent | `png-demo-admins`, `png-demo-users` | `ServiceDesk.Agent` | Can resolve requests; "my requests" returns A's requests |
| B: employee | `png-demo-users` | none | Sees only their own requests; a status update is refused **by the MCP server** |
| C: assets only (optional) | `png-demo-assets-only` | none | Service-desk tools denied **by Unity Catalog** (no `EXECUTE`) |

Assign the app role as owner of the `png-demo-mcp-api` enterprise application (Entra portal → Enterprise applications
→ Users and groups). List the same users in `demo_users` (`infra/azure` and the bundle), so the MCP seed data and the
Delta history agree.

## Least privilege

| Principal | Gets |
|---|---|
| End users (groups) | `USE CATALOG`/`USE SCHEMA`, `SELECT` on `lakehouse`, `CAN_USE` on the warehouse, `CAN_RUN` on Genie, `CAN_USE` on the app, `EXECUTE` on the MCP services |
| App service principal | Nothing: every call uses the user's token (scopes `serving.serving-endpoints`, `dashboards.genie`, `ai-gateway`) |
| Connection owner | `USE CONNECTION` (nobody else) |
| Access Connector managed identity | `Storage Blob Data Contributor` on the one storage account |
| MCP pull identity | `AcrPull` on the one registry |
| Entra apps | No Graph application permissions, no admin consent (client pre-authorised by the API owner) |
| Client secret | 90 days, generated and piped into the Connections API, never printed or stored |

Create Genie spaces in a folder with restricted permissions (not `/Workspace/Shared`) and grant `CAN_RUN` to groups.

## Verify

| Check | How |
|---|---|
| Private Link | `databricks bundle run generate_ops_data` writes to the managed location; storage logs show only `dfs` requests from private IPs (query below) |
| Private network gateway | `databricks bundle run connectivity_check`: `/healthz` 200 and `/mcp` 401 (no token) from serverless |
| Not public | The MCP hostnames have no public DNS and aren't reachable from the internet |
| On behalf of the user | MCP server log: `user=<UPN> client=<client appId> scp=MCP.Access roles=… src=<gateway subnet IP>` (`az containerapp logs show -g <rg> -n service-desk-mcp`) |
| Per-user sign-in | `databricks ai-gateway get-mcp-service-user-mapped-credential mcp-services/ops_demo.tools.service_desk`: not found before sign-in, `ACTIVE` after |

```kusto
StorageBlobLogs
| extend endpoint = tostring(split(tostring(parse_url(Uri).Host), '.')[1]),
         ip = tostring(split(CallerIpAddress, ':')[0]), code = toint(StatusCode)
| summarize requests = count(), ok = countif(code < 400), denied = countif(code == 403)
    by endpoint, src = iff(ipv4_is_private(ip), 'private', 'public'), AuthenticationType
```

Storage request logs appear in Log Analytics a few minutes after diagnostics are enabled. Serverless compute picks up
NCC changes when it starts: restart a SQL warehouse that was already running when you attached the NCC or added rules.

The gateway resolves destination names on the gateway side, so test connectivity with HTTP requests rather than local
DNS lookups inside serverless.

## Add a new internal MCP service: no network changes

Connectivity scales **by network, not by endpoint**. The gateway destination is the Container Apps environment's
**domain suffix**, and the private DNS zone has a wildcard record. So any new app `<name>.<environment domain>` is
reachable from serverless as soon as it runs.

| Step | Change | Where |
|---|---|---|
| 1 | Add the server to `mcp_servers`: `{ server = "<tool set>" }` for the bundled image, or `{ image = "<repo>:<tag>" }` for your own image pushed to the registry (`az acr build`) | `infra/azure/terraform.tfvars` → `terraform apply` |
| 2 | Create its per-user OAuth connection; the script picks up every app from `terraform output mcp_urls` and only creates missing connections | `./scripts/04-create-mcp-connections.sh` |
| 3 | Register it as an MCP service with grants (copy one of the `mcp_services` entries) | `bundle/databricks.yml` |
| 4 | Let the app use it: append `ops_demo.tools.<service>` to `app_mcp_services` | bundle variable → `databricks bundle deploy` |
| 5 | Users sign in once to the new MCP service (Unity Gateway → MCPs → *Login*) | per user |

```hcl
# infra/azure/terraform.tfvars
mcp_servers = {
  "service-desk-mcp"    = { server = "service_desk" }
  "asset-inventory-mcp" = { server = "asset_inventory" }
  "knowledge-base-mcp"  = { image = "knowledge-base-mcp:v1" }   # new: <name>.<env domain>, no network change
}
```

**What stays the same:** the NCC, the private network gateway and its destinations, DNS, peering, NSG rules, private
endpoints and approvals. Steps 2–4 are the Unity Catalog governance steps any MCP service needs.

**Services outside the Container Apps environment** (another VNet, a VM, on-premises over ExpressRoute or VPN): make
the host routable and resolvable from the hub VNet (peering or routes, a private DNS zone or a custom resolver in
`private_dns_resolvers`), then add **one destination** (hostname or domain suffix) to the gateway: `destinations` in
`infra/databricks-account/main.tf`. Then do steps 2–5.

## Reset before a demo

The MCP servers keep their data in memory; restarting restores the seed:

```bash
RG=$(terraform -chdir=infra/azure output -raw resource_group_name)
for app in service-desk-mcp asset-inventory-mcp; do
  az containerapp revision restart -g "$RG" -n $app \
    --revision "$(az containerapp revision list -g "$RG" -n $app --query "[0].name" -o tsv)"
done
```

To show the state before the gateway exists: `terraform -chdir=infra/databricks-account apply -var enable_png=false`.

## Teardown

Order matters: the gateway uses the delegated subnet, and the NCC private endpoints target the storage account.

```bash
(cd bundle && databricks bundle destroy)                       # app, jobs, MCP services + grants
databricks connections delete ops_demo.tools.service_desk_conn
databricks connections delete ops_demo.tools.asset_inventory_conn
databricks genie trash-space "$(cat .state/genie_space_id)"
terraform -chdir=infra/databricks-workspace destroy            # catalog (incl. managed tables), location, credential, warehouse
terraform -chdir=infra/databricks-account destroy              # binding, gateway, PE rules, NCC, groups
terraform -chdir=infra/azure destroy                           # everything in the resource group
source .state/entra.env
az ad app delete --id "$MCP_CLIENT_APP_ID" && az ad app delete --id "$MCP_API_APP_ID"
rm -rf .state
```

The private network gateway and NCC private endpoints incur charges; tear the demo down when you no longer need it.
