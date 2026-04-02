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
            description = "The base URL of the Bigeye service used for access-decision requests"
          } },
          { api_key = {
            type = "string",
            required = false,
            encrypted = true,
            referenceable = true,
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
            encrypted = true,
            referenceable = true,
            description = "Password for Basic Auth with Bigeye service"
          } },
          { timeout = {
            type = "number",
            required = false,
            default = 5000,
            description = "Timeout in milliseconds for the HTTP request to Bigeye"
          } },
          { database_name = {
            type = "string",
            required = false,
            description = "The name of the database to query"
          } },
          { tables = {
            type = "array",
            required = false,
            elements = {
              type = "string",
            },
            description = "List of table names as strings"
          } },
          { columns = {
            type = "array",
            required = false,
            elements = {
              type = "string",
            },
            description = "List of column names as strings"
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
