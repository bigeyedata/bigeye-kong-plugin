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

\* Either `api_key` or `username`+`password` must be provided. `username` and `password` are mutually required.

### Context extraction

The plugin extracts database context from the request before sending it to Bigeye. Request values take precedence over plugin configuration fallbacks.

| Field | Query param | Header | Body field | Config fallback |
|---|---|---|---|---|
| SQL query | `query` or `sql` | — | `query` or `sql` | — |
| Database | `database` or `db` | `x-database` or `x-db-name` | `database` or `db` | `database_name` |
| Tables | `tables` | `x-tables` | `tables` | `tables` |
| Columns | `columns` | `x-columns` | `columns` | `columns` |

Tables and columns in query params and headers can be provided as a JSON array or a comma-separated string.

Sensitive headers (`Authorization`, `Cookie`, `x-api-key`, `Proxy-Authorization`) are stripped before sending request data to Bigeye; note that the `apikey` header used by Kong's key-auth plugin is not currently stripped.

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
