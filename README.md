# bigeye-kong-plugin

A Kong Gateway plugin that enforces data access policies via [Bigeye](https://www.bigeye.com). On each incoming request, the plugin calls Bigeye's access-decision API and blocks the request with a `403` if access is denied. Errors and non-deny responses allow the request through (fail-open).

## How it works

For every request passing through a route or service where the plugin is enabled, the plugin:

1. Extracts context from the request — SQL query, database name, tables, columns, and AI agent metadata
2. Sends the context to `POST /api/v1/access-decision` on your Bigeye instance
3. Blocks with `403 Access Denied` if Bigeye returns `ACCESS_DECISION_DENY`; otherwise allows the request to proceed

The plugin is fail-open: if Bigeye is unreachable, times out, or returns an unexpected response, the request is allowed through.

## Configuration

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `bigeye_url` | string | yes | — | Base URL of your Bigeye instance (e.g. `https://bigeye.example.com`) |
| `workspace_id` | number | yes | — | Bigeye workspace ID |
| `api_key` | string | no* | — | API key for Bearer token authentication |
| `username` | string | no* | — | Username for Basic Auth |
| `password` | string | no* | — | Password for Basic Auth |
| `timeout` | number | no | `5000` | HTTP timeout in milliseconds |
| `database_name` | string | no | — | Fallback database name sent to Bigeye |
| `tables` | array of strings | no | — | Fallback list of table names sent to Bigeye |
| `columns` | array of strings | no | — | Fallback list of column names sent to Bigeye |
| `warehouse_type` | number | no | `0` | WarehouseType enum for access objects (`0`=unspecified, `2`=BigQuery, `10`=Snowflake, etc.) |
| `evaluate_policy` | boolean | no | `false` | When `true`, instructs Bigeye to run the policy engine for the conversation |
| `evaluate_policy_timeout` | number | no | — | Timeout (ms) for requests when `evaluate_policy` is `true`; falls back to `timeout` when unset |

\* Either `api_key` or `username`+`password` must be provided. `username` and `password` are mutually required.

### Context extraction

The plugin extracts context from the request before sending it to Bigeye. Request values take precedence over plugin configuration fallbacks.

| Field | Query param | Header | Body field | Config fallback |
|---|---|---|---|---|
| SQL query | `query` or `sql` | — | `query` or `sql` | — |
| Database | `database` or `db` | `x-database` or `x-db-name` | `database` or `db` | `database_name` |
| Tables | `tables` | `x-tables` | `tables` | `tables` |
| Columns | `columns` | `x-columns` | `columns` | `columns` |
| Conversation ID | — | `x-conversation-id` or `x-session-id` | — | — |
| Agent ID | — | `x-agent-id` | — | — |
| AI agent ID | — | `x-ai-agent-id` | — | — |

Tables and columns in query params and headers can be provided as a JSON array or a comma-separated string. `x-conversation-id` takes precedence over `x-session-id` when both are present.

## Local development

The plugin uses [Pongo](https://github.com/Kong/kong-pongo) for local testing inside a real Kong Gateway instance.

### Prerequisites

- [Docker](https://www.docker.com/)
- Pongo: `git clone https://github.com/Kong/kong-pongo && cd kong-pongo && make install`

### Start a local Kong instance with the plugin loaded

```bash
pongo init
pongo up
KONG_DATABASE=off KONG_DECLARATIVE_CONFIG=/kong-plugin/kong.yml KONG_PREFIX=/tmp/kong_prefix pongo shell
```

Inside the Pongo shell, start Kong:

```bash
kms -y
```

### Configure the plugin

Copy `kong.yml.tmpl` to `kong.yml` and fill in your Bigeye credentials:

```yaml
- name: bigeye-kong-plugin
  config:
    bigeye_url: http://host.docker.internal:8080
    username: <username>
    password: <password>
    workspace_id: <workspace_id>
```

`host.docker.internal` resolves to your host machine from inside the Docker container, so you can point at a locally running Bigeye instance.

### Send a test request

```bash
curl -i "http://localhost:8000/query?sql=SELECT+*+FROM+users&database=production" \
  -H "apikey: my-secret-api-key"
```

### Run the integration tests

```bash
pongo run
```

## Deploying to an existing Kong instance

### Option 1: Kong Admin API

Add the plugin to an existing service or route via the Kong Admin API:

```bash
curl -X POST http://localhost:8001/services/{service-id}/plugins \
  -H "Content-Type: application/json" \
  -d '{
    "name": "bigeye-kong-plugin",
    "config": {
      "bigeye_url": "https://bigeye.example.com",
      "api_key": "your-bigeye-api-key",
      "workspace_id": 12345,
      "timeout": 5000
    }
  }'
```

Or on a specific route:

```bash
curl -X POST http://localhost:8001/routes/{route-id}/plugins \
  -H "Content-Type: application/json" \
  -d '{
    "name": "bigeye-kong-plugin",
    "config": {
      "bigeye_url": "https://bigeye.example.com",
      "api_key": "your-bigeye-api-key",
      "workspace_id": 12345
    }
  }'
```

### Option 2: Declarative configuration (deck / kong.yml)

Add the plugin to your declarative config file:

```yaml
plugins:
  - name: bigeye-kong-plugin
    service: your-service-name
    config:
      bigeye_url: https://bigeye.example.com
      api_key: your-bigeye-api-key
      workspace_id: 12345
      timeout: 5000
      database_name: production
      tables:
        - users
        - orders
      columns:
        - email
        - phone_number
```

Apply with [deck](https://docs.konghq.com/deck/):

```bash
deck sync --state kong.yml
```

### Installing the plugin on Kong nodes

The plugin Lua source must be present on each Kong node. Copy the plugin directory to Kong's plugin path:

```
kong/plugins/bigeye-kong-plugin/
├── handler.lua
└── schema.lua
```

Then add the plugin to Kong's `plugins` configuration:

```bash
# In kong.conf
plugins = bundled,bigeye-kong-plugin

# Or as an environment variable
KONG_PLUGINS=bundled,bigeye-kong-plugin
```

Restart Kong after installing: `kong restart`.

## Deploying as a Kong AI Gateway AI Custom Policy

This plugin can be registered as a [Kong AI Custom Policy](https://developer.konghq.com/ai-gateway/entities/ai-custom-policy/) to enforce Bigeye access controls on AI Gateway traffic (e.g. requests to OpenAI, Anthropic, and other AI backends).

### Schema compatibility

The plugin schema satisfies all Kong AI Custom Policy validation rules:
- The schema `name` (`bigeye-kong-plugin`) matches the installed plugin name
- The schema uses only built-in entity validators (`mutually_required`, `at_least_one_of`) — no `custom_validator` or `custom_entity_check`

### Deployment modes

**Installed mode** (recommended): Install the plugin on each data plane first (see [Installing the plugin on Kong nodes](#installing-the-plugin-on-kong-nodes)), then register only the schema with Konnect.

**Streaming mode**: Upload both the schema and handler to Konnect for automatic distribution to data planes. Requires `KONG_CUSTOM_PLUGIN_STREAMING_ENABLED=on` on each data plane.

### Step 1: Register as an AI Custom Policy

#### Installed mode — Konnect API

```bash
export LUA_SCHEMA=$(cat kong/plugins/bigeye-kong-plugin/schema.lua | tr -d '\n')

curl -X POST "https://{region}.api.konghq.com/v1/ai-gateways/{AIGatewayId}/custom-policies" \
  --header "Authorization: Bearer $KONNECT_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{
    "name": "bigeye-kong-plugin",
    "type": "installed",
    "display_name": "Bigeye Kong Plugin",
    "schema": "'"$LUA_SCHEMA"'"
  }'
```

#### Installed mode — kongctl

```yaml
ai_gateway_custom_policies:
  - ref: bigeye-kong-plugin
    ai_gateway: !lookup {id: !env AI_GATEWAY_ID}
    name: bigeye-kong-plugin
    type: installed
    display_name: Bigeye Kong Plugin
    schema: !env BIGEYE_KONG_PLUGIN_SCHEMA
```

```bash
export BIGEYE_KONG_PLUGIN_SCHEMA=$(cat kong/plugins/bigeye-kong-plugin/schema.lua)
```

#### Streaming mode — kongctl

```yaml
ai_gateway_custom_policies:
  - ref: bigeye-kong-plugin
    ai_gateway: !lookup {id: !env AI_GATEWAY_ID}
    name: bigeye-kong-plugin
    type: streaming
    display_name: Bigeye Kong Plugin
    schema: !env BIGEYE_KONG_PLUGIN_SCHEMA
    handler: !env BIGEYE_KONG_PLUGIN_HANDLER
```

```bash
export BIGEYE_KONG_PLUGIN_SCHEMA=$(cat kong/plugins/bigeye-kong-plugin/schema.lua)
export BIGEYE_KONG_PLUGIN_HANDLER=$(cat kong/plugins/bigeye-kong-plugin/handler.lua)
```

### Step 2: Attach as an AI Policy

Once the AI Custom Policy is registered, create an AI Policy with `type: bigeye-kong-plugin` to apply it. The plugin can be attached at any scope (global, AI service, AI consumer, etc.).

#### Konnect API

```bash
curl -X POST "https://{region}.api.konghq.com/v1/ai-gateways/{AIGatewayId}/policies" \
  --header "Authorization: Bearer $KONNECT_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{
    "name": "bigeye-access-policy",
    "display_name": "Bigeye Access Policy",
    "type": "bigeye-kong-plugin",
    "enabled": true,
    "global": true,
    "config": {
      "bigeye_url": "https://bigeye.example.com",
      "api_key": "your-bigeye-api-key",
      "workspace_id": 12345,
      "evaluate_policy": true,
      "evaluate_policy_timeout": 15000
    }
  }'
```

#### kongctl

```yaml
ai_gateway_policies:
  - ref: bigeye-access-policy
    ai_gateway: !lookup {id: !env AI_GATEWAY_ID}
    display_name: Bigeye Access Policy
    name: bigeye-access-policy
    type: bigeye-kong-plugin
    enabled: true
    global: true
    config:
      bigeye_url: !env BIGEYE_URL
      api_key: !env BIGEYE_API_KEY
      workspace_id: !env BIGEYE_WORKSPACE_ID
      evaluate_policy: true
      evaluate_policy_timeout: 15000
```

Set the required environment variables:

```bash
export BIGEYE_URL=https://bigeye.example.com
export BIGEYE_API_KEY=your-bigeye-api-key
export BIGEYE_WORKSPACE_ID=12345
```

### Passing conversation context

The plugin identifies AI conversations via headers. Set these on requests routed through the AI Gateway:

| Header | Purpose |
|---|---|
| `x-conversation-id` | Links the request to a Bigeye conversation for policy evaluation |
| `x-agent-id` | Identifies the agent making the request |
| `x-ai-agent-id` | Sets the AI agent external ID sent to Bigeye |

When `evaluate_policy: true`, Bigeye evaluates the policy engine for the conversation identified by `x-conversation-id`. Use `evaluate_policy_timeout` to allow extra time for policy evaluation, as it may take longer than a standard access-decision check.
