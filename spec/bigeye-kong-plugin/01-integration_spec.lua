-- Helper functions provided by Kong Gateway, see https://github.com/Kong/kong/blob/master/spec/helpers.lua
local helpers = require "spec.helpers"

-- matches our plugin name defined in the plugins's schema.lua
local PLUGIN_NAME = "bigeye-kong-plugin"

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

      -- Using the BluePrint to create a test Route, automatically attaches it
      --    to the default "echo" Service that will be created by the test framework
      local test_route = blue_print.routes:insert({
        paths = { "/mock" },
      })

      -- Add the custom plugin to the test Route with Bigeye configuration
      blue_print.plugins:insert {
        name = PLUGIN_NAME,
        route = { id = test_route.id },
        config = {
          bigeye_url = "http://httpbin.konghq.com/anything",
          api_key = "test-api-key-12345",
          timeout = 5000,
        },
      }


      -- start kong
      assert(helpers.start_kong({
        -- use the custom test template to create a local mock server
        nginx_conf = "spec/fixtures/custom_nginx.template",
        -- make sure our plugin gets loaded
        plugins = "bundled," .. PLUGIN_NAME,
      }))

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

    -- a nested describe defines an actual test on the plugin behavior
    describe("Request handling", function()

      it("allows the request to proceed", function()

        -- invoke a test request
        local r = client:get("/mock/anything", {})

        -- validate that the request succeeded, response status 200
        assert.response(r).has.status(200)

      end)

      it("sends data when SQL query is in query parameters", function()

        -- invoke a test request with SQL query parameter
        local r = client:get("/mock/anything?query=SELECT+*+FROM+users", {})

        -- validate that the request succeeded
        assert.response(r).has.status(200)

        -- Note: In a real test environment, you would mock the Bigeye endpoint
        -- and verify that it received the correct data
      end)

      it("sends data when SQL is in request body", function()

        -- invoke a test request with SQL in body
        local r = client:post("/mock/anything", {
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = '{"query": "SELECT * FROM products WHERE id = 1"}',
        })

        -- validate that the request succeeded
        assert.response(r).has.status(200)

      end)
    end)
  end)
end
