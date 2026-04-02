local http  = require("resty.http")
local cjson = require("cjson.safe")

local BigeyeKongPluginHandler = {
  PRIORITY = 1000,
  VERSION = "0.0.1",
}

-- Helper function to parse a string into a list (array)
-- Tries JSON decoding first, then falls back to comma-separated parsing
local function parse_string_list(input)
  if type(input) ~= "string" then
    return nil
  end

  -- Try JSON decode first
  local parsed, json_err = cjson.decode(input)
  if not json_err and type(parsed) == "table" then
    return parsed
  end

  -- Fall back to comma-separated parsing
  local result = {}
  for item in input:gmatch("([^,]+)") do
    table.insert(result, item:match("^%s*(.-)%s*$")) -- trim whitespace
  end
  return result
end

function BigeyeKongPluginHandler:access(conf)
  kong.log.debug("Bigeye plugin access phase triggered")

  -- Warn if using HTTP instead of HTTPS for Bigeye URL
  if conf.bigeye_url:lower():match("^http://") then
    kong.log.warn("Bigeye URL uses HTTP instead of HTTPS. Authentication credentials will be sent in plaintext.")
  end

  -- Capture request information
  local req_headers = kong.request.get_headers()

  -- Get authenticated consumer (set by auth plugins like key-auth, jwt, basic-auth, etc.)
  local consumer = kong.client.get_consumer()

  -- Strip sensitive headers before forwarding to Bigeye to prevent credential leakage
  local safe_req_headers = {}
  for k, v in pairs(req_headers) do
    local lower = k:lower()
    if lower ~= "authorization" and lower ~= "cookie" and lower ~= "x-api-key" and lower ~= "proxy-authorization" then
      safe_req_headers[k] = v
    end
  end

  local request_data = {
    method = kong.request.get_method(),
    path = kong.request.get_path(),
    query = kong.request.get_query(),
    headers = safe_req_headers,
    timestamp = ngx.time(),
    -- Extract AI agent metadata from headers
    agent_metadata = {
      agent_id = req_headers["x-ai-agent-id"],
      agent_type = req_headers["x-ai-agent-type"],
      user_id = req_headers["x-user-id"],
      session_id = req_headers["x-session-id"],
    },
    -- Include only consumer custom_id (null if no consumer)
    consumer = consumer and consumer.custom_id or nil,
  }

  -- Try to capture the request body if it exists (may contain SQL queries)
  local body, body_err = kong.request.get_body()
  if body_err then
    kong.log.warn("Failed to read request body: ", body_err)
  elseif body then
    request_data.body = body
  end

  -- Extract SQL query if present in common locations
  -- Check query parameters for SQL
  if request_data.query and request_data.query.query then
    request_data.sql = request_data.query.query
  elseif request_data.query and request_data.query.sql then
    request_data.sql = request_data.query.sql
  end

  -- Check body for SQL if it's a table
  if type(body) == "table" then
    if body.query then
      if request_data.sql then
        kong.log.debug("SQL query in body is overriding query parameter value")
      end
      request_data.sql = body.query
    elseif body.sql then
      if request_data.sql then
        kong.log.debug("SQL query in body is overriding query parameter value")
      end
      request_data.sql = body.sql
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
    if req_headers["x-database"] then
      request_data.database = req_headers["x-database"]
    elseif req_headers["x-db-name"] then
      request_data.database = req_headers["x-db-name"]
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

  -- Use database_name from config if not found in request
  if not request_data.database and conf.database_name then
    request_data.database = conf.database_name
  end

  -- Extract tables from common locations
  -- Check query parameters
  if request_data.query and request_data.query.tables then
    if type(request_data.query.tables) == "string" then
      request_data.tables = parse_string_list(request_data.query.tables)
    elseif type(request_data.query.tables) == "table" then
      request_data.tables = request_data.query.tables
    end
  end

  -- Check headers
  if not request_data.tables and req_headers["x-tables"] then
    request_data.tables = parse_string_list(req_headers["x-tables"])
  end

  -- Check body if it's a table
  if not request_data.tables and type(body) == "table" then
    if body.tables then
      if type(body.tables) == "table" then
        request_data.tables = body.tables
      elseif type(body.tables) == "string" then
        request_data.tables = parse_string_list(body.tables)
      end
    end
  end

  -- Use tables from config if not found in request
  if not request_data.tables and conf.tables then
    request_data.tables = conf.tables
  end

  -- Extract columns from common locations
  -- Check query parameters
  if request_data.query and request_data.query.columns then
    if type(request_data.query.columns) == "string" then
      request_data.columns = parse_string_list(request_data.query.columns)
    elseif type(request_data.query.columns) == "table" then
      request_data.columns = request_data.query.columns
    end
  end

  -- Check headers
  if not request_data.columns and req_headers["x-columns"] then
    request_data.columns = parse_string_list(req_headers["x-columns"])
  end

  -- Check body if it's a table
  if not request_data.columns and type(body) == "table" then
    if body.columns then
      if type(body.columns) == "table" then
        request_data.columns = body.columns
      elseif type(body.columns) == "string" then
        request_data.columns = parse_string_list(body.columns)
      end
    end
  end

  -- Use columns from config if not found in request
  if not request_data.columns and conf.columns then
    request_data.columns = conf.columns
  end

  -- Send to Bigeye synchronously (we need to block on the response)
  local httpc = http.new()
  httpc:set_timeout(conf.timeout)

  -- Prepare headers
  local bigeye_headers = {
    ["Content-Type"] = "application/json",
  }

  -- Add authentication
  if conf.username and conf.password then
    local auth = ngx.encode_base64(conf.username .. ":" .. conf.password)
    bigeye_headers["Authorization"] = "Basic " .. auth
  elseif conf.api_key then
    bigeye_headers["Authorization"] = "Bearer " .. conf.api_key
  end

  -- Encode the data as JSON
  local request_body, encode_err = cjson.encode(request_data)
  if encode_err then
    kong.log.err("Failed to encode data for Bigeye: ", encode_err)
    return
  end

  kong.log.debug("Request to Bigeye - URL: ", conf.bigeye_url .. "/api/v1/access-decision")
  -- Redact Authorization header for security
  local safe_headers = {}
  for k, v in pairs(bigeye_headers) do
    if k == "Authorization" then
      safe_headers[k] = "[REDACTED]"
    else
      safe_headers[k] = v
    end
  end
  kong.log.debug("Request to Bigeye - Headers: ", cjson.encode(safe_headers))
  kong.log.debug("Request to Bigeye - Body: ", request_body)

  -- Send the request
  local res, request_err = httpc:request_uri(conf.bigeye_url .. "/api/v1/access-decision", {
    method = "POST",
    headers = bigeye_headers,
    body = request_body,
  })

  if request_err then
    kong.log.err("Failed to send request to Bigeye: ", request_err)
    -- On error, allow the request (fail open)
    return
  end

  -- Set keepalive for connection reuse
  local ok, keepalive_err = httpc:set_keepalive(10000, 100)
  if not ok then
    kong.log.debug("Failed to set keepalive: ", keepalive_err)
  end

  kong.log.debug("Response from Bigeye - Status: ", res.status)
  kong.log.debug("Response from Bigeye - Headers: ", cjson.encode(res.headers))
  kong.log.debug("Response from Bigeye - Body: ", res.body)

  -- Check HTTP status code
  if res.status ~= 200 then
    kong.log.err("Bigeye returned non-200 status: ", res.status, " body: ", res.body)
    -- On error, allow the request (fail open)
    return
  end

  -- Parse the response
  local response_data, decode_err = cjson.decode(res.body)
  if decode_err then
    kong.log.err("Failed to decode Bigeye response: ", decode_err)
    -- On error, allow the request (fail open)
    return
  end

  -- Check if access is denied
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
