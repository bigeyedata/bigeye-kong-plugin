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

  local req_headers = kong.request.get_headers()
  local req_query = kong.request.get_query()

  -- Try to capture the request body if it exists (may contain SQL queries)
  local body, body_err = kong.request.get_body()
  if body_err then
    kong.log.warn("Failed to read request body: ", body_err)
  end

  -- Pre-extract MCP JSON-RPC tool call arguments (only for tools/call method to avoid false matches)
  local mcp_args
  if type(body) == "table" and body.method == "tools/call"
      and type(body.params) == "table" and type(body.params.arguments) == "table" then
    mcp_args = body.params.arguments
  end

  -- Extract SQL query from query parameters, then body (body takes precedence)
  local sql
  if req_query.query then
    sql = req_query.query
  elseif req_query.sql then
    sql = req_query.sql
  end
  if type(body) == "table" then
    if body.query then
      if sql then kong.log.debug("SQL query in body is overriding query parameter value") end
      sql = body.query
    elseif body.sql then
      if sql then kong.log.debug("SQL query in body is overriding query parameter value") end
      sql = body.sql
    end
  end
  if not sql and mcp_args then
    sql = mcp_args.query or mcp_args.sql
  end

  -- Extract database name: query param > header > body > config
  local database
  if req_query.database then
    database = req_query.database
  elseif req_query.db then
    database = req_query.db
  end
  if not database then
    database = req_headers["x-database"] or req_headers["x-db-name"]
  end
  if not database and type(body) == "table" then
    database = body.database or body.db
  end
  if not database and mcp_args then
    database = mcp_args.database or mcp_args.db
  end
  if not database and conf.database_name then
    database = conf.database_name
  end

  -- Extract table names: query param > header > body > config
  local tables
  if req_query.tables then
    if type(req_query.tables) == "string" then
      tables = parse_string_list(req_query.tables)
    elseif type(req_query.tables) == "table" then
      tables = req_query.tables
    end
  end
  if not tables and req_headers["x-tables"] then
    tables = parse_string_list(req_headers["x-tables"])
  end
  if not tables and type(body) == "table" and body.tables then
    if type(body.tables) == "table" then
      tables = body.tables
    elseif type(body.tables) == "string" then
      tables = parse_string_list(body.tables)
    end
  end
  if not tables and mcp_args and mcp_args.tables then
    if type(mcp_args.tables) == "table" then
      tables = mcp_args.tables
    elseif type(mcp_args.tables) == "string" then
      tables = parse_string_list(mcp_args.tables)
    end
  end
  if not tables and conf.tables then
    tables = conf.tables
  end

  -- Extract column names: query param > header > body > config
  local columns
  if req_query.columns then
    if type(req_query.columns) == "string" then
      columns = parse_string_list(req_query.columns)
    elseif type(req_query.columns) == "table" then
      columns = req_query.columns
    end
  end
  if not columns and req_headers["x-columns"] then
    columns = parse_string_list(req_headers["x-columns"])
  end
  if not columns and type(body) == "table" and body.columns then
    if type(body.columns) == "table" then
      columns = body.columns
    elseif type(body.columns) == "string" then
      columns = parse_string_list(body.columns)
    end
  end
  if not columns and mcp_args and mcp_args.columns then
    if type(mcp_args.columns) == "table" then
      columns = mcp_args.columns
    elseif type(mcp_args.columns) == "string" then
      columns = parse_string_list(mcp_args.columns)
    end
  end
  if not columns and conf.columns then
    columns = conf.columns
  end

  -- Build accessObjects array matching AccessDecisionRequest proto JSON (camelCase).
  -- AccessObjectType: COLUMN=1, TABLE=2, SQL=3
  local access_objects = {}
  if sql then
    table.insert(access_objects, {
      type = 3,
      sourceType = conf.warehouse_type,
      sourceName = database,
      externalId = sql,
    })
  end
  if tables then
    for _, table_name in ipairs(tables) do
      table.insert(access_objects, {
        type = 2,
        sourceType = conf.warehouse_type,
        sourceName = table_name,
      })
    end
  end
  if columns then
    for _, column_name in ipairs(columns) do
      table.insert(access_objects, {
        type = 1,
        sourceType = conf.warehouse_type,
        sourceName = column_name,
      })
    end
  end

  -- Build aiAgent from x-ai-agent-id and x-ai-agent-description headers if present.
  -- get_header() guarantees a single string even when the header is repeated.
  local ai_agent_external_id = kong.request.get_header("x-ai-agent-id")
  local ai_agent_description = kong.request.get_header("x-ai-agent-description")
  local ai_agent = nil
  if ai_agent_external_id then
    ai_agent = { externalId = ai_agent_external_id }
    if ai_agent_description then
      ai_agent.description = ai_agent_description
    end
  elseif ai_agent_description then
    kong.log.warn("x-ai-agent-description set without x-ai-agent-id; description will not be sent to Bigeye")
  end

  -- Extract initialPrompt: x-initial-prompt header takes precedence; fall back to first user message in body.
  -- Handles both string content and multi-modal array content (OpenAI format).
  local initial_prompt = kong.request.get_header("x-initial-prompt")
  if not initial_prompt and type(body) == "table" and type(body.messages) == "table" then
    for _, msg in ipairs(body.messages) do
      if type(msg) == "table" and msg.role == "user" then
        if type(msg.content) == "string" then
          initial_prompt = msg.content
        elseif type(msg.content) == "table" then
          -- Multi-modal content: extract text from the first text part
          for _, part in ipairs(msg.content) do
            if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
              initial_prompt = part.text
              break
            end
          end
        end
        break
      end
    end
  end

  -- Extract username from x-username header
  local username = kong.request.get_header("x-username")

  -- Proto3 JSON uses camelCase field names
  local request_data = {
    operation = kong.request.get_method(),
    path = kong.request.get_path(),
    timestamp = ngx.time(),
    workspace = conf.workspace_id,
    aiAgent = ai_agent,
    accessObjects = #access_objects > 0 and access_objects or nil,
    -- x-agent-id takes priority; fall back to x-ai-agent-id when only the AI agent header is present
    agentExternalId = kong.request.get_header("x-agent-id") or kong.request.get_header("x-ai-agent-id"),
    -- x-conversation-id takes precedence over x-session-id
    conversationExternalId = kong.request.get_header("x-conversation-id") or kong.request.get_header("x-session-id"),
    -- only include evaluatePolicy when explicitly enabled to avoid sending proto3 default
    evaluatePolicy = conf.evaluate_policy or nil,
    initialPrompt = initial_prompt or nil,
    username = username or nil,
  }

  -- Send to Bigeye synchronously (we need to block on the response)
  local httpc = http.new()
  local timeout = (conf.evaluate_policy and conf.evaluate_policy_timeout) or conf.timeout
  httpc:set_timeout(timeout)

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
  -- Redact Authorization header and PII fields for security
  local safe_headers = {}
  for k, v in pairs(bigeye_headers) do
    if k == "Authorization" then
      safe_headers[k] = "[REDACTED]"
    else
      safe_headers[k] = v
    end
  end
  kong.log.debug("Request to Bigeye - Headers: ", cjson.encode(safe_headers))
  local safe_body = {}
  for k, v in pairs(request_data) do
    if k == "username" or k == "initialPrompt" then
      safe_body[k] = "[REDACTED]"
    else
      safe_body[k] = v
    end
  end
  kong.log.debug("Request to Bigeye - Body: ", cjson.encode(safe_body))

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
  if response_data.policyDecisions then
    kong.log.debug("Bigeye policy decisions: ", cjson.encode(response_data.policyDecisions))
  end
  -- overall_decision is the authoritative field when policy evaluation is enabled;
  -- fall back to accessDecision for responses that predate policy evaluation
  local decision = response_data.overallDecision or response_data.accessDecision
  if decision == "ACCESS_DECISION_DENY" then
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
