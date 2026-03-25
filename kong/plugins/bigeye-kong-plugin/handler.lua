local http  = require("resty.http")
local cjson = require("cjson.safe")

local MyPluginHandler = {
  PRIORITY = 1000,
  VERSION = "0.0.1",
}

function MyPluginHandler:response(conf)

  kong.log("response handler")

  local httpc = http.new()

  local res, err = httpc:request_uri("http://httpbin.konghq.com/anything", {
    method = "GET",
  })

  if err then
    return kong.response.error(500,
      "Error when trying to access third-party service: " .. err,
      { ["Content-Type"] = "text/html" })
  end

  local body_table, err = cjson.decode(res.body)

  if err then
    return kong.response.error(500,
      "Error when decoding third-party service response: " .. err,
      { ["Content-Type"] = "text/html" })
  end

  kong.response.set_header(conf.response_header_name, body_table.url)

end

return MyPluginHandler
