# Identity and access: on-behalf-of the user, rooted in Entra ID

Both halves of the demo — access to Databricks and access to the private MCP servers — are rooted
in **Microsoft Entra ID** and use **OAuth 2.0**. No PATs, no static API keys, no shared service
account at the MCP server: every MCP call carries the **end user's** identity.

## Identity chain (on-behalf-of)

```
 User ──Entra ID SSO (OIDC)──► Databricks
   │                             Entra groups → Databricks account groups
   │                             (png-demo-admins, png-demo-users, png-demo-assets-only)
   ▼
 Databricks App "Operations Assistant"
   │  user authorization: the app calls Databricks APIs with the signed-in user's
   │  Databricks OAuth token (scopes limited to what the app declares)
   ▼
 Unity AI Gateway  ── runs as the user ──► UC checks EXECUTE on the MCP service for *this user*
   │
   ▼
 UC connection (OAuth U2M, per user)
   │  uses *this user's* Entra token for the MCP API
   │  (obtained once via authorization code + PKCE; refreshed with the refresh token)
   │  token: aud=png-demo-mcp-api  azp=png-demo-mcp-client  scp=MCP.Access
   │         oid / preferred_username = the user   roles=[ServiceDesk.Agent]?
   ▼
 PNG ──► MCP server (Container Apps, internal)
         validates JWT (iss, aud, azp, scp, exp, signature via Entra JWKS)
         authorises per user (oid, roles) and records the user on writes
```

| Hop | Mechanism | Identity at the receiver | Who authorises |
|---|---|---|---|
| User → Databricks | Entra ID SSO | User | Entra (sign-in, Conditional Access, MFA) |
| App → Databricks | Databricks Apps **user authorization** | User | UC: table grants, Genie, `EXECUTE` on MCP services |
| Unity AI Gateway → MCP | UC connection **OAuth U2M (per user)** | User (delegated Entra token) | MCP server: scope, app roles, data ownership |
| Catalog storage | Access Connector managed identity | Access Connector | Azure RBAC + UC grants |

**Two layers of authorisation, one identity:**
1. **Unity Catalog** decides whether the user may use the tool at all (`EXECUTE` on the MCP service, group membership).
2. **The system of record** decides what that user may do in it (own requests only, agent-only
   status updates), using claims from the user's own Entra token.

The user's identity is never re-asserted by the app — the app cannot impersonate someone else,
because the token for the MCP API was issued by Entra to that user.

## Entra configuration

| Object | Setting | Why |
|---|---|---|
| `png-demo-mcp-api` | Identifier URI `api://<appId>`, v2 tokens | Audience of MCP tokens |
| `png-demo-mcp-api` | Delegated scope **`MCP.Access`** (user + admin consent display text) | What the client may request on behalf of the user |
| `png-demo-mcp-api` | App role **`ServiceDesk.Agent`** (allowed member type: users/groups) | Per-user authorisation in the MCP server |
| `png-demo-mcp-api` | `preAuthorizedApplications` = `png-demo-mcp-client` for `MCP.Access` | No consent prompt and **no admin consent** needed |
| `png-demo-mcp-api` service principal | Assign `ServiceDesk.Agent` to demo user A (as app owner) | Role shows up in A's token as `roles` |
| `png-demo-mcp-client` | Web platform **redirect URI** = the one Databricks shows when creating the U2M connection | Authorization code flow back to Databricks |
| `png-demo-mcp-client` | Client secret (90 days), created at connection time, piped straight into UC | Confidential client; never written to disk |
| `png-demo-mcp-client` | Required resource access: `png-demo-mcp-api` / `MCP.Access`, plus `offline_access` | Refresh tokens so users sign in once |

Least privilege: no Microsoft Graph application permissions, no admin consent, no tenant-wide
settings. The app owner (you) can pre-authorise the client and assign the app role.

## MCP server checks

| Check | Claim | Rule |
|---|---|---|
| Issuer | `iss` | `https://login.microsoftonline.com/<tenant>/v2.0` |
| Audience | `aud` | `png-demo-mcp-api` appId (v2) — also accept `api://<appId>` |
| Calling client | `azp` | must equal `png-demo-mcp-client` appId |
| Delegated, not app-only | `scp` | must contain `MCP.Access` (reject app-only tokens without `scp`) |
| User | `oid`, `preferred_username` | stamped on writes, used for `mine=true` filters, logged |
| Role | `roles` | `ServiceDesk.Agent` required for `update_request_status` |
| Freshness / signature | `exp`, `nbf`, JWKS `kid` | standard JWT validation, JWKS cached |

The server logs `user`, `azp`, `scp`, `roles` per call — never the token.

## Demo moments

1. **Two users, same question, different answers** — "show my open requests" returns each user's own
   requests; only User A (`ServiceDesk.Agent`) can resolve a request. The refusal for User B comes from
   the MCP server, based on B's Entra token.
2. **The requester is real** — `create_request` from the app shows the user's UPN in the internal system.
3. **UC still gates first** — a `png-demo-assets-only` user can't reach the service-desk tools at all
   (UC denies `EXECUTE` on the MCP service before any token is used).
4. **Audit on both sides** — Entra sign-in logs (user sign-ins to `png-demo-mcp-client`) and
   Unity AI Gateway usage, correlated with MCP server logs.
5. **Revoke** — remove User A's app role or revoke their sessions in Entra → the next call reflects it
   (after token expiry / refresh), while PNG stays up.

## Alternative: shared identity (OAuth M2M)

If the system of record has no per-user model, the connection can use **client credentials** instead:
one service-principal token for all users. UC still governs who may use the connection, but the MCP
server sees only `png-demo-mcp-client` (`roles`, no `scp`, no user). Use this only when per-user
authorisation in the target system isn't needed.

## If the MCP server uses a different identity provider

Examples: Okta, Ping, Auth0, Keycloak, ADFS, or Entra ID **in another tenant**. Databricks sign-in and
the App/Unity AI Gateway user authorization stay on Entra; only the U2M connection's OAuth provider changes.

### 1. In the MCP server's IdP

| Task | Notes |
|---|---|
| Register a **confidential client** for Databricks | Grant types `authorization_code` (+ PKCE) and `refresh_token` |
| Add the **redirect URI** Databricks shows when you create the connection | Copy it from the connection setup |
| Define the **API / audience and delegated scopes** | Okta: custom authorization server audience + scope; Auth0: API identifier + permissions; Keycloak: client scope + audience mapper; Entra (other tenant): `api://…` + delegated scope |
| Model roles / groups as **token claims** | Okta: groups claim; Auth0: RBAC permissions; Keycloak: realm/client roles |
| Assign users / groups to the client | Only assigned users can complete sign-in |
| Allow refresh tokens / set lifetimes | Okta / Auth0: `offline_access`; check refresh token rotation policy |

### 2. In Databricks (UC connection, OAuth U2M)

| Field | Value |
|---|---|
| Authorization endpoint | New IdP's `/authorize` |
| Token endpoint | New IdP's `/token` |
| Client ID / secret | From the new IdP |
| Scopes | The delegated scopes + `offline_access` (or IdP equivalent) |

Unchanged: MCP service registration, `EXECUTE` grants, app code, PNG.

### 3. In the MCP server

Make issuer, audience, allowed clients and claim names configuration so the same image runs on any IdP.

| | Entra ID | Okta | Auth0 | Keycloak |
|---|---|---|---|---|
| Issuer | `https://login.microsoftonline.com/<tid>/v2.0` | `https://<org>.okta.com/oauth2/<server-id>` | `https://<tenant>.auth0.com/` | `https://<host>/realms/<realm>` |
| Client claim | `azp` | `cid` | `azp` | `azp` |
| Scope claim | `scp` (space-separated) | `scp` (array) | `scope` | `scope` |
| User claim | `oid`, `preferred_username` | `uid`, `sub` | `sub` | `sub`, `preferred_username` |
| Roles | `roles` | custom `groups` claim | `permissions` | `realm_access.roles` / `resource_access` |

### 4. Identity mapping

- The user is now **two identities**: Entra (Databricks) and the MCP IdP (connection sign-in).
  UC knows the Databricks user; the MCP server knows the IdP user. Nothing links them automatically.
- Preferred: **federate** the MCP IdP with Entra (Entra as upstream IdP / SAML-OIDC federation), so
  connection sign-in is SSO, the user is the same person in both, and Conditional Access applies.
- Otherwise map on a stable attribute (email / UPN) and keep both directories in sync (SCIM).

### 5. Network

| Flow | Requirement |
|---|---|
| User's browser → IdP `/authorize` | Reachable from users' devices (normal corporate access) |
| Databricks → IdP `/token` (code exchange, refresh) | Sent from the Databricks **control plane**, not serverless: the token endpoint must be reachable from the control plane (public endpoint, or allowlist the control-plane outbound IPs) |
| MCP server → IdP JWKS | Outbound from the Container Apps environment (NAT / firewall from the spoke) |

### 6. Entra ID in another tenant

- Register the API (scope, app roles) in the MCP's tenant; create the client there, or make
  `png-demo-mcp-client` multi-tenant and consent it into that tenant (requires an admin there).
- Users from the workspace tenant must exist in the MCP tenant (B2B guests) to get delegated tokens.
- The issuer becomes the other tenant; the MCP server trusts only that issuer.
- Network is separate from identity: the PNG subnet's VNet must still be in the workspace's tenant,
  with the MCP network connected to it (peering / private endpoint).

## Verified during build

- Connections are created via the Connections API with authorization + token endpoint, client ID/secret and
  scope `api://<mcp-api>/MCP.Access offline_access`; they report `credential_type: OAUTH_U2M_MAPPING`
  (per user). Redirect URI: `https://<workspace>/login/oauth/http.html`. Exchange method `body_only`.
- Before a user signs in, `get-mcp-service-user-mapped-credential` returns *credential … not found … please
  login first*; after sign-in it is `ACTIVE`.
- A call from the App (user authorization, scope `ai-gateway`) through Unity Gateway uses the **calling user's**
  credential. MCP server log: `user=<UPN> client=<mcp-client appId> scp=MCP.Access roles=ServiceDesk.Agent
  src=10.60.0.4` — the source is the PNG subnet.
- OAuth code exchange and refresh run from the Databricks **control plane**, so the IdP token endpoint must be
  reachable from there (Entra's is public).
- End users need `EXECUTE` on the MCP service (plus `USE CATALOG` / `USE SCHEMA`), not `USE CONNECTION`.
