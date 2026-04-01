local typedefs = require "kong.db.schema.typedefs"

local PLUGIN_NAME = "bigeye-kong-plugin"

local schema = {
  name = PLUGIN_NAME,
  fields = {
    { config = {
        type = "record",
        fields = {
          { bigeye_url = {
            type = "string",
            required = true,
            description = "The URL of the Bigeye service to send notifications to"
          } },
          { api_key = {
            type = "string",
            required = false,
            description = "API key for authenticating with Bigeye service"
          } },
          { username = {
            type = "string",
            required = false,
            description = "Username for Basic Auth with Bigeye service"
          } },
          { password = {
            type = "string",
            required = false,
            description = "Password for Basic Auth with Bigeye service"
          } },
          { timeout = {
            type = "number",
            required = false,
            default = 5000,
            description = "Timeout in milliseconds for the HTTP request to Bigeye"
          } },
        },
        entity_checks = {
          { mutually_required = { "username", "password" } },
          { at_least_one_of = { "api_key", "username" } },
        },
      },
    },
  },
}

return schema
