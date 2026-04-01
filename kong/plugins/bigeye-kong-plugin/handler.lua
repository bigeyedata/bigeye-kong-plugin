local http  = require("resty.http")
local cjson = require("cjson.safe")

local BigeyeKongPluginHandler = {
  PRIORITY = 1000,
  VERSION = "0.0.1",
}

local function send_to_bigeye(conf, data)
  local httpc = http.new()
  httpc:set_timeout(conf.timeout)

  -- Prepare headers
  local headers = {
    ["Content-Type"] = "application/json",
  }

  -- Add authentication
  if conf.username and conf.password then
    local auth = ngx.encode_base64(conf.username .. ":" .. conf.password)
    headers["Authorization"] = "Basic " .. auth
  elseif conf.api_key then
    headers["Authorization"] = "Bearer " .. conf.api_key
  end

  -- Encode the data as JSON
  local body, err = cjson.encode(data)
  if err then
    kong.log.err("Failed to encode data for Bigeye: ", err)
    return
  end

  kong.log.debug("Request to Bigeye - URL: ", conf.bigeye_url .. "/api/v1/access-decision")
  kong.log.debug("Request to Bigeye - Headers: ", cjson.encode(headers))
  kong.log.debug("Request to Bigeye - Body: ", body)

  -- Send the request (fire and forget style)
  local res, err = httpc:request_uri(conf.bigeye_url .. "/api/v1/access-decision", {
    method = "POST",
    headers = headers,
    body = body,
  })

  if err then
    kong.log.err("Failed to send request to Bigeye: ", err)
    return
  end

  kong.log.debug("Response from Bigeye - Status: ", res.status)
  kong.log.debug("Response from Bigeye - Headers: ", cjson.encode(res.headers))
  kong.log.debug("Response from Bigeye - Body: ", res.body)

  if res.status >= 400 then
    kong.log.warn("Bigeye returned error status: ", res.status, " body: ", res.body)
  else
    kong.log.debug("Successfully sent notification to Bigeye, status: ", res.status)
  end

  httpc:close()
end

function BigeyeKongPluginHandler:access(conf)
  kong.log.debug("Bigeye plugin access phase triggered")

  -- Capture request information
  local headers = kong.request.get_headers()

  -- Get authenticated consumer (set by auth plugins like key-auth, jwt, basic-auth, etc.)
  local consumer = kong.client.get_consumer()

  local request_data = {
    method = kong.request.get_method(),
    path = kong.request.get_path(),
    query = kong.request.get_query(),
    headers = headers,
    timestamp = ngx.time(),
    -- Extract AI agent metadata from headers
    agent_metadata = {
      agent_id = headers["x-ai-agent-id"],
      agent_type = headers["x-ai-agent-type"],
      user_id = headers["x-user-id"],
      session_id = headers["x-session-id"],
    },
    -- Include only consumer custom_id (null if no consumer)
    consumer = consumer and consumer.custom_id or nil,
  }

  -- Try to capture the request body if it exists (may contain SQL queries)
  local body, err = kong.request.get_body()
  if body then
    request_data.body = body
  end

  -- Extract SQL query if present in common locations
  -- Check query parameters for SQL
  if request_data.query and request_data.query.query then
    request_data.sql_query = request_data.query.query
  elseif request_data.query and request_data.query.sql then
    request_data.sql_query = request_data.query.sql
  end

  -- Check body for SQL if it's a table
  if type(body) == "table" then
    if body.query then
      request_data.sql_query = body.query
    elseif body.sql then
      request_data.sql_query = body.sql
    end
  end

  -- Extract database name from common locations
  -- Check query parameters
  if request_data.query and request_data.query.database then
    request_data.database = request_data.query.database
  elseif request_data.query and request_data.query.db then
    request_data.database = request_data.query.db
  end

  -- Check headers
  if not request_data.database then
    if headers["x-database"] then
      request_data.database = headers["x-database"]
    elseif headers["x-db-name"] then
      request_data.database = headers["x-db-name"]
    end
  end

  -- Check body if it's a table
  if not request_data.database and type(body) == "table" then
    if body.database then
      request_data.database = body.database
    elseif body.db then
      request_data.database = body.db
    end
  end

  -- Send to Bigeye synchronously (we need to block on the response)
  local httpc = http.new()
  httpc:set_timeout(conf.timeout)

  -- Prepare headers
  local headers = {
    ["Content-Type"] = "application/json",
  }

  -- Add authentication
  if conf.username and conf.password then
    local auth = ngx.encode_base64(conf.username .. ":" .. conf.password)
    headers["Authorization"] = "Basic " .. auth
  elseif conf.api_key then
    headers["Authorization"] = "Bearer " .. conf.api_key
  end

  -- Encode the data as JSON
  local request_body, err = cjson.encode(request_data)
  if err then
    kong.log.err("Failed to encode data for Bigeye: ", err)
    return
  end

  kong.log.debug("Request to Bigeye - URL: ", conf.bigeye_url .. "/api/v1/access-decision")
  kong.log.debug("Request to Bigeye - Headers: ", cjson.encode(headers))
  kong.log.debug("Request to Bigeye - Body: ", request_body)

  -- Send the request
  local res, err = httpc:request_uri(conf.bigeye_url .. "/api/v1/access-decision", {
    method = "POST",
    headers = headers,
    body = request_body,
  })

  httpc:close()

  if err then
    kong.log.err("Failed to send request to Bigeye: ", err)
    -- On error, allow the request (fail open)
    return
  end

  kong.log.debug("Response from Bigeye - Status: ", res.status)
  kong.log.debug("Response from Bigeye - Headers: ", cjson.encode(res.headers))
  kong.log.debug("Response from Bigeye - Body: ", res.body)

  -- Parse the response
  local response_data, err = cjson.decode(res.body)
  if err then
    kong.log.err("Failed to decode Bigeye response: ", err)
    -- On error, allow the request (fail open)
    return
  end

  -- Check if access is denied (ACCESS_DECISION_DENY = 3)
  kong.log.debug("Response from Bigeye - response_data: ", cjson.encode(response_data))
  if response_data.accessDecision == "ACCESS_DECISION_DENY" then
    local reason = response_data.reason or "Access denied by Bigeye"
    kong.log.warn("Blocking request - Bigeye decision: DENY - Reason: ", reason)
    return kong.response.exit(403, {
      message = "Access denied",
      reason = reason
    })
  end

  kong.log.debug("Bigeye decision: ALLOW or WARN - allowing request")
end

return BigeyeKongPluginHandler
