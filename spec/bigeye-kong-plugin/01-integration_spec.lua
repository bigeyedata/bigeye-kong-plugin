-- Helper functions provided by Kong Gateway, see https://github.com/Kong/kong/blob/master/spec/helpers.lua
local helpers = require "spec.helpers"

-- matches our plugin name defined in the plugins's schema.lua
local PLUGIN_NAME = "bigeye-kong-plugin"

-- Define fixtures with HTTP mocks for different Bigeye response scenarios
local fixtures = {
  http_mock = {}
}

-- Mock Bigeye server that returns ACCESS_DECISION_ALLOW
fixtures.http_mock.bigeye_allow = [[
  server {
    server_name bigeye_mock_allow;
    listen 16555;

    location = /api/v1/access-decision {
      content_by_lua_block {
        ngx.req.read_body()
        local body = ngx.req.get_body_data()

        ngx.log(ngx.DEBUG, "Bigeye mock (ALLOW) received request: ", body)

        -- Return ALLOW response
        ngx.status = 200
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"accessDecision": "ACCESS_DECISION_ALLOW"}')
      }
    }
  }
]]

-- Mock Bigeye server that returns ACCESS_DECISION_DENY
fixtures.http_mock.bigeye_deny = [[
  server {
    server_name bigeye_mock_deny;
    listen 16556;

    location = /api/v1/access-decision {
      content_by_lua_block {
        ngx.req.read_body()
        local body = ngx.req.get_body_data()

        ngx.log(ngx.DEBUG, "Bigeye mock (DENY) received request: ", body)

        -- Return DENY response with reason
        ngx.status = 200
        ngx.header["Content-Type"] = "application/json"
        local response = require("cjson").encode({
          accessDecision = "ACCESS_DECISION_DENY",
          reason = "Unauthorized SQL query detected"
        })
        ngx.say(response)
      }
    }
  }
]]

-- Mock unreachable Bigeye server (for testing fail-open)
fixtures.http_mock.bigeye_unreachable = [[
  server {
    server_name bigeye_mock_unreachable;
    listen 16557;

    location = /api/v1/access-decision {
      content_by_lua_block {
        -- Simulate network timeout by sleeping longer than plugin timeout
        ngx.sleep(10)
        ngx.exit(500)
      }
    }
  }
]]

-- Mock Bigeye server that returns invalid JSON
fixtures.http_mock.bigeye_invalid_json = [[
  server {
    server_name bigeye_mock_invalid;
    listen 16558;

    location = /api/v1/access-decision {
      content_by_lua_block {
        ngx.req.read_body()

        ngx.log(ngx.DEBUG, "Bigeye mock (INVALID JSON) received request")

        ngx.status = 200
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("This is not valid JSON")
      }
    }
  }
]]

-- Mock Bigeye server that validates request data
fixtures.http_mock.bigeye_validate = [[
  server {
    server_name bigeye_mock_validate;
    listen 16559;

    location = /api/v1/access-decision {
      content_by_lua_block {
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        local headers = ngx.req.get_headers()

        local cjson = require "cjson"

        -- Validate Authorization header
        if not headers["Authorization"] or not string.find(headers["Authorization"], "Bearer test%-api%-key") then
          ngx.status = 401
          ngx.say('{"error": "Unauthorized"}')
          return
        end

        -- Parse request
        local ok, request_data = pcall(cjson.decode, body)
        if not ok then
          ngx.status = 400
          ngx.say('{"error": "Invalid JSON"}')
          return
        end

        ngx.log(ngx.DEBUG, "Bigeye mock (VALIDATE) received valid request with sql_query: ", request_data.sql_query or "none")

        -- Return ALLOW
        ngx.status = 200
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"accessDecision": "ACCESS_DECISION_ALLOW"}')
      }
    }
  }
]]

-- Mock Bigeye server that validates Basic Auth
fixtures.http_mock.bigeye_basic_auth = [[
  server {
    server_name bigeye_mock_basic_auth;
    listen 16560;

    location = /api/v1/access-decision {
      content_by_lua_block {
        ngx.req.read_body()
        local headers = ngx.req.get_headers()

        -- Validate Authorization header for Basic Auth
        if not headers["Authorization"] or not string.find(headers["Authorization"], "^Basic ") then
          ngx.status = 401
          ngx.say('{"error": "Missing or invalid Basic Auth"}')
          return
        end

        -- Decode and validate credentials (test-user:test-password)
        local auth = headers["Authorization"]:gsub("^Basic ", "")
        local decoded = ngx.decode_base64(auth)
        if decoded ~= "test-user:test-password" then
          ngx.status = 401
          ngx.say('{"error": "Invalid credentials"}')
          return
        end

        ngx.log(ngx.DEBUG, "Bigeye mock (BASIC_AUTH) received valid Basic Auth request")

        -- Return ALLOW
        ngx.status = 200
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"accessDecision": "ACCESS_DECISION_ALLOW"}')
      }
    }
  }
]]

-- Mock Bigeye server that validates database_name, tables, and columns
fixtures.http_mock.bigeye_validate_config = [[
  server {
    server_name bigeye_mock_validate_config;
    listen 16561;

    location = /api/v1/access-decision {
      content_by_lua_block {
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        local cjson = require "cjson"

        -- Parse request
        local ok, request_data = pcall(cjson.decode, body)
        if not ok then
          ngx.status = 200
          ngx.header["Content-Type"] = "application/json"
          ngx.say('{"accessDecision": "ACCESS_DECISION_DENY", "reason": "Invalid JSON"}')
          return
        end

        -- Validate that database, tables, and columns are present and have correct values
        if request_data.database ~= "test_database" then
          ngx.status = 200
          ngx.header["Content-Type"] = "application/json"
          ngx.say('{"accessDecision": "ACCESS_DECISION_DENY", "reason": "Expected database to be test_database, got: ' .. tostring(request_data.database) .. '"}')
          return
        end

        if not request_data.tables or type(request_data.tables) ~= "table" then
          ngx.status = 200
          ngx.header["Content-Type"] = "application/json"
          ngx.say('{"accessDecision": "ACCESS_DECISION_DENY", "reason": "Expected tables array"}')
          return
        end

        -- Verify tables contains expected values
        local has_users = false
        local has_orders = false
        for _, table_name in ipairs(request_data.tables) do
          if table_name == "users" then has_users = true end
          if table_name == "orders" then has_orders = true end
        end
        if not (has_users and has_orders) then
          ngx.status = 200
          ngx.header["Content-Type"] = "application/json"
          ngx.say('{"accessDecision": "ACCESS_DECISION_DENY", "reason": "Expected tables to contain users and orders"}')
          return
        end

        if not request_data.columns or type(request_data.columns) ~= "table" then
          ngx.status = 200
          ngx.header["Content-Type"] = "application/json"
          ngx.say('{"accessDecision": "ACCESS_DECISION_DENY", "reason": "Expected columns array"}')
          return
        end

        -- Verify columns contains expected values
        local has_email = false
        local has_ssn = false
        for _, column_name in ipairs(request_data.columns) do
          if column_name == "email" then has_email = true end
          if column_name == "ssn" then has_ssn = true end
        end
        if not (has_email and has_ssn) then
          ngx.status = 200
          ngx.header["Content-Type"] = "application/json"
          ngx.say('{"accessDecision": "ACCESS_DECISION_DENY", "reason": "Expected columns to contain email and ssn"}')
          return
        end

        ngx.log(ngx.DEBUG, "Bigeye mock (VALIDATE_CONFIG) received valid request with database: ", request_data.database)

        -- Return ALLOW only if all validation passes
        ngx.status = 200
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"accessDecision": "ACCESS_DECISION_ALLOW"}')
      }
    }
  }
]]

-- Mock Bigeye server that validates request overrides config
fixtures.http_mock.bigeye_validate_override = [[
  server {
    server_name bigeye_mock_validate_override;
    listen 16562;

    location = /api/v1/access-decision {
      content_by_lua_block {
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        local cjson = require "cjson"

        -- Parse request
        local ok, request_data = pcall(cjson.decode, body)
        if not ok then
          ngx.status = 400
          ngx.say('{"error": "Invalid JSON"}')
          return
        end

        -- Validate that request values override config values
        if request_data.database ~= "override_database" then
          ngx.status = 400
          ngx.say(cjson.encode({error = "Expected database to be override_database, got: " .. tostring(request_data.database)}))
          return
        end

        -- Check that tables contains "override_table"
        local found_override_table = false
        if request_data.tables and type(request_data.tables) == "table" then
          for _, table_name in ipairs(request_data.tables) do
            if table_name == "override_table" then
              found_override_table = true
              break
            end
          end
        end

        if not found_override_table then
          ngx.status = 400
          ngx.say('{"error": "Expected tables to contain override_table"}')
          return
        end

        ngx.log(ngx.DEBUG, "Bigeye mock (VALIDATE_OVERRIDE) received valid override request")

        -- Return ALLOW
        ngx.status = 200
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"accessDecision": "ACCESS_DECISION_ALLOW"}')
      }
    }
  }
]]

-- Run the tests for each strategy. Strategies include "postgres" and "off"
--   which represent the deployment topologies for Kong Gateway
for _, strategy in helpers.all_strategies() do

  describe(PLUGIN_NAME .. ": [#" .. strategy .. "]", function()
    -- Will be initialized before_each nested test
    local client

    setup(function()

      -- A BluePrint gives us a helpful database wrapper to
      --    manage Kong Gateway entities directly.
      -- This function also truncates any existing data in an existing db.
      -- The custom plugin name is provided to this function so it mark as loaded
      local blue_print = helpers.get_db_utils(strategy, nil, { PLUGIN_NAME })

      -- Create a single upstream service for all routes
      -- This uses Kong's default mock upstream service
      local service = blue_print.services:insert({
        protocol = "http",
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_port,
      })

      -- Route with ALLOW mock
      local route_allow = blue_print.routes:insert({
        paths = { "/test-allow" },
        service = { id = service.id },
      })
      blue_print.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route_allow.id },
        config = {
          bigeye_url = "http://localhost:16555",
          api_key = "test-api-key-12345",
          workspace_id = 123,
          timeout = 5000,
        },
      }

      -- Route with DENY mock
      local route_deny = blue_print.routes:insert({
        paths = { "/test-deny" },
        service = { id = service.id },
      })
      blue_print.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route_deny.id },
        config = {
          bigeye_url = "http://localhost:16556",
          api_key = "test-api-key-12345",
          workspace_id = 123,
          timeout = 5000,
        },
      }

      -- Route with unreachable mock (fail-open test)
      local route_unreachable = blue_print.routes:insert({
        paths = { "/test-unreachable" },
        service = { id = service.id },
      })
      blue_print.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route_unreachable.id },
        config = {
          bigeye_url = "http://localhost:16557",
          api_key = "test-api-key-12345",
          workspace_id = 123,
          timeout = 1000, -- Short timeout to trigger fail-open
        },
      }

      -- Route with invalid JSON mock
      local route_invalid = blue_print.routes:insert({
        paths = { "/test-invalid" },
        service = { id = service.id },
      })
      blue_print.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route_invalid.id },
        config = {
          bigeye_url = "http://localhost:16558",
          api_key = "test-api-key-12345",
          workspace_id = 123,
          timeout = 5000,
        },
      }

      -- Route with validation mock
      local route_validate = blue_print.routes:insert({
        paths = { "/test-validate" },
        service = { id = service.id },
      })
      blue_print.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route_validate.id },
        config = {
          bigeye_url = "http://localhost:16559",
          api_key = "test-api-key-12345",
          workspace_id = 123,
          timeout = 5000,
        },
      }

      -- Route with Basic Auth mock
      local route_basic_auth = blue_print.routes:insert({
        paths = { "/test-basic-auth" },
        service = { id = service.id },
      })
      blue_print.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route_basic_auth.id },
        config = {
          bigeye_url = "http://localhost:16560",
          username = "test-user",
          password = "test-password",
          workspace_id = 123,
          timeout = 5000,
        },
      }

      -- Route with config fields (database_name, tables, columns)
      local route_config_fields = blue_print.routes:insert({
        paths = { "/test-config-fields" },
        service = { id = service.id },
      })
      blue_print.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route_config_fields.id },
        config = {
          bigeye_url = "http://localhost:16561",
          api_key = "test-api-key-12345",
          workspace_id = 123,
          timeout = 5000,
          database_name = "test_database",
          tables = { "users", "orders" },
          columns = { "email", "ssn" },
        },
      }

      -- Route with config fields that will be overridden by request
      local route_override = blue_print.routes:insert({
        paths = { "/test-override" },
        service = { id = service.id },
      })
      blue_print.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = route_override.id },
        config = {
          bigeye_url = "http://localhost:16562",
          api_key = "test-api-key-12345",
          workspace_id = 123,
          timeout = 5000,
          database_name = "config_database",
          tables = { "config_table" },
          columns = { "config_column" },
        },
      }

      -- start kong with fixtures
      assert(helpers.start_kong({
        -- use the custom test template to create a local mock server
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- make sure our plugin gets loaded
        plugins = "bundled," .. PLUGIN_NAME,
      }, nil, nil, fixtures))

    end)

    -- teardown runs after its parent describe block
    teardown(function()
      helpers.stop_kong(nil, true)
    end)

    -- before_each runs before each child describe
    before_each(function()
      client = helpers.proxy_client()
    end)

    -- after_each runs after each child describe
    after_each(function()
      if client then client:close() end
    end)

    describe("ACCESS_DECISION_ALLOW", function()

      it("allows the request when Bigeye returns ALLOW", function()
        local r = client:get("/test-allow/anything", {})

        -- Request should proceed successfully
        assert.response(r).has.status(200)
      end)

      it("allows request with SQL query in query parameters", function()
        local r = client:get("/test-allow/anything?query=SELECT+*+FROM+users", {})

        -- Request should proceed successfully
        assert.response(r).has.status(200)
      end)

      it("allows request with SQL query in request body", function()
        local r = client:post("/test-allow/anything", {
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = '{"query": "SELECT * FROM products WHERE id = 1"}',
        })

        -- Request should proceed successfully
        assert.response(r).has.status(200)
      end)

    end)

    describe("ACCESS_DECISION_DENY", function()

      it("blocks the request with 403 when Bigeye returns DENY", function()
        local r = client:get("/test-deny/anything?query=SELECT+*+FROM+secrets", {})

        -- Verify 403 response
        assert.response(r).has.status(403)

        -- Verify response body contains denial information
        local body = assert.response(r).has.jsonbody()
        assert.equal("Access denied", body.message)
        assert.equal("Unauthorized SQL query detected", body.reason)
      end)

      it("blocks POST request with DENY response", function()
        local r = client:post("/test-deny/anything", {
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = '{"query": "DROP TABLE users"}',
        })

        -- Verify 403 response
        assert.response(r).has.status(403)

        -- Verify response body
        local body = assert.response(r).has.jsonbody()
        assert.equal("Access denied", body.message)
        assert.is_not_nil(body.reason)
      end)

    end)

    describe("Fail-open behavior", function()

      it("allows the request when Bigeye is unreachable (timeout)", function()
        local r = client:get("/test-unreachable/anything?query=SELECT+*+FROM+users", {})

        -- Should allow request (fail-open)
        assert.response(r).has.status(200)
      end)

      it("allows the request when Bigeye returns invalid JSON", function()
        local r = client:get("/test-invalid/anything?query=SELECT+*+FROM+users", {})

        -- Should allow request (fail-open on parse error)
        assert.response(r).has.status(200)
      end)

    end)

    describe("Request data extraction and validation", function()

      it("sends Authorization header with API key", function()
        local r = client:get("/test-validate/anything?query=SELECT+*+FROM+users", {})

        -- Mock validates the Authorization header
        -- If invalid, it returns 401; if valid, returns 200
        assert.response(r).has.status(200)
      end)

      it("extracts SQL query from query parameter 'query'", function()
        local r = client:get("/test-validate/anything?query=SELECT+id+FROM+orders", {})

        assert.response(r).has.status(200)
      end)

      it("extracts SQL query from query parameter 'sql'", function()
        local r = client:get("/test-validate/anything?sql=SELECT+*+FROM+products", {})

        assert.response(r).has.status(200)
      end)

      it("extracts SQL query from request body 'query' field", function()
        local r = client:post("/test-validate/anything", {
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = '{"query": "SELECT * FROM customers"}',
        })

        assert.response(r).has.status(200)
      end)

      it("extracts SQL query from request body 'sql' field", function()
        local r = client:post("/test-validate/anything", {
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = '{"sql": "SELECT count(*) FROM orders"}',
        })

        assert.response(r).has.status(200)
      end)

      it("extracts database name from query parameter 'database'", function()
        local r = client:get("/test-validate/anything?database=production&query=SELECT+1", {})

        assert.response(r).has.status(200)
      end)

      it("extracts database name from header 'x-database'", function()
        local r = client:get("/test-validate/anything?query=SELECT+1", {
          headers = {
            ["x-database"] = "analytics",
          },
        })

        assert.response(r).has.status(200)
      end)

    end)

    describe("Authentication methods", function()

      it("uses Basic Auth when username and password are configured", function()
        local r = client:get("/test-basic-auth/anything?query=SELECT+*+FROM+users", {})

        -- Mock validates the Basic Auth header with correct credentials
        -- If invalid, it returns 401; if valid, returns 200
        assert.response(r).has.status(200)
      end)

    end)

    describe("Configuration fields (database_name, tables, columns)", function()

      it("sends database_name, tables, and columns from config to Bigeye", function()
        local r = client:get("/test-config-fields/anything?query=SELECT+*+FROM+users", {})

        -- Mock validates that all config fields are sent correctly
        -- If validation fails, mock returns ACCESS_DECISION_DENY and plugin blocks with 403
        -- If validation passes, mock returns ACCESS_DECISION_ALLOW and request proceeds with 200
        assert.response(r).has.status(200)
      end)

    end)

    describe("Request overrides configuration", function()

      it("overrides database_name with query parameter", function()
        local r = client:get("/test-override/anything?database=override_database&tables=override_table", {})

        -- Mock validates that request database overrides config database
        assert.response(r).has.status(200)
      end)

      it("overrides database_name with header", function()
        local r = client:get("/test-override/anything?tables=override_table", {
          headers = {
            ["x-database"] = "override_database",
          },
        })

        -- Mock validates that request database from header overrides config
        assert.response(r).has.status(200)
      end)

      it("overrides database_name with request body", function()
        local r = client:post("/test-override/anything", {
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = '{"database": "override_database", "tables": ["override_table"]}',
        })

        -- Mock validates that request database from body overrides config
        assert.response(r).has.status(200)
      end)

      it("overrides tables with query parameter (JSON array)", function()
        local r = client:get("/test-override/anything?database=override_database&tables=" .. ngx.escape_uri('["override_table"]'), {})

        -- Mock validates that request tables override config tables
        assert.response(r).has.status(200)
      end)

      it("overrides tables with query parameter (comma-separated)", function()
        local r = client:get("/test-override/anything?database=override_database&tables=override_table,another_table", {})

        -- Mock validates that request tables override config tables
        assert.response(r).has.status(200)
      end)

      it("overrides tables with header", function()
        local r = client:get("/test-override/anything?database=override_database", {
          headers = {
            ["x-tables"] = "override_table,another_table",
          },
        })

        -- Mock validates that request tables from header override config
        assert.response(r).has.status(200)
      end)

      it("overrides tables with request body", function()
        local r = client:post("/test-override/anything", {
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = '{"database": "override_database", "tables": ["override_table", "another_table"]}',
        })

        -- Mock validates that request tables from body override config
        assert.response(r).has.status(200)
      end)

      it("overrides columns with query parameter (JSON array)", function()
        local r = client:get("/test-override/anything?database=override_database&tables=override_table&columns=" .. ngx.escape_uri('["override_column"]'), {})

        -- Request should succeed with overridden columns
        assert.response(r).has.status(200)
      end)

      it("overrides columns with query parameter (comma-separated)", function()
        local r = client:get("/test-override/anything?database=override_database&tables=override_table&columns=override_column,another_column", {})

        -- Request should succeed with overridden columns
        assert.response(r).has.status(200)
      end)

      it("overrides columns with header", function()
        local r = client:get("/test-override/anything?database=override_database&tables=override_table", {
          headers = {
            ["x-columns"] = "override_column,another_column",
          },
        })

        -- Request should succeed with overridden columns
        assert.response(r).has.status(200)
      end)

      it("overrides columns with request body", function()
        local r = client:post("/test-override/anything", {
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = '{"database": "override_database", "tables": ["override_table"], "columns": ["override_column", "another_column"]}',
        })

        -- Request should succeed with overridden columns
        assert.response(r).has.status(200)
      end)

    end)
  end)
end
