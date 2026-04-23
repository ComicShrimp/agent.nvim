--- ACP (Agent Client Protocol) library
--- JSON-RPC 2.0 over stdio
--- https://agentclientprotocol.com

local json = vim.json

local M = {}

-- ── JSON-RPC primitives ──────────────────────────────────────────────────────

local _id = 0
local function next_id()
  _id = _id + 1
  return _id
end

--- Encode a JSON-RPC request (expects a response)
---@param method string
---@param params table
---@return string  newline-terminated JSON
function M.request(method, params)
  return json.encode({ jsonrpc = "2.0", id = next_id(), method = method, params = params }) .. "\n"
end

--- Encode a JSON-RPC notification (no response expected)
---@param method string
---@param params table
---@return string
function M.notify(method, params)
  return json.encode({ jsonrpc = "2.0", method = method, params = params }) .. "\n"
end

--- Encode a JSON-RPC response
---@param id integer|string
---@param result table
---@return string
function M.respond(id, result)
  return json.encode({ jsonrpc = "2.0", id = id, result = result }) .. "\n"
end

--- Encode a JSON-RPC error response
---@param id integer|string|nil
---@param code integer
---@param message string
---@param data? table
---@return string
function M.error_response(id, code, message, data)
  local err = { code = code, message = message }
  if data then err.data = data end
  return json.encode({ jsonrpc = "2.0", id = id, result = vim.NIL, error = err }) .. "\n"
end

--- Parse a raw JSON line into a message table.
--- Returns nil + error string on failure.
---@param line string
---@return table|nil, string|nil
function M.parse(line)
  local ok, msg = pcall(json.decode, line)
  if not ok then return nil, "json decode error: " .. tostring(msg) end
  return msg, nil
end

--- Return true if msg is a request (has id + method)
function M.is_request(msg) return msg.id ~= nil and msg.method ~= nil end

--- Return true if msg is a notification (method, no id)
function M.is_notification(msg) return msg.id == nil and msg.method ~= nil end

--- Return true if msg is a response (has id, no method)
function M.is_response(msg) return msg.id ~= nil and msg.method == nil end

-- ── Error codes ──────────────────────────────────────────────────────────────

M.errors = {
  PARSE_ERROR      = -32700,
  INVALID_REQUEST  = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS   = -32602,
  INTERNAL_ERROR   = -32603,
  AUTH_REQUIRED    = -32000,
  RESOURCE_NOT_FOUND = -32002,
}

-- ── Agent → Client requests ──────────────────────────────────────────────────

--- initialize: negotiate version + capabilities
---@param protocol_version integer
---@param client_info? table  {name, version, title?}
---@param client_capabilities? table
function M.initialize(protocol_version, client_info, client_capabilities)
  return M.request("initialize", {
    protocolVersion    = protocol_version,
    clientInfo         = client_info,
    clientCapabilities = client_capabilities or { fs = { readTextFile = false, writeTextFile = false }, terminal = false },
  })
end

--- authenticate
---@param method_id string
function M.authenticate(method_id)
  return M.request("authenticate", { methodId = method_id })
end

--- session/new
---@param cwd string  absolute path
---@param mcp_servers? table[]
function M.session_new(cwd, mcp_servers)
  return M.request("session/new", { cwd = cwd, mcpServers = mcp_servers or {} })
end

--- session/load
---@param session_id string
---@param cwd string
---@param mcp_servers? table[]
function M.session_load(session_id, cwd, mcp_servers)
  return M.request("session/load", { sessionId = session_id, cwd = cwd, mcpServers = mcp_servers or {} })
end

--- session/prompt
---@param session_id string
---@param prompt table[]  array of ContentBlock
function M.session_prompt(session_id, prompt)
  return M.request("session/prompt", { sessionId = session_id, prompt = prompt })
end

--- session/cancel  (notification)
---@param session_id string
function M.session_cancel(session_id)
  return M.notify("session/cancel", { sessionId = session_id })
end

--- session/list
---@param cwd? string
---@param cursor? string
function M.session_list(cwd, cursor)
  return M.request("session/list", { cwd = cwd, cursor = cursor })
end

--- session/set_mode
---@param session_id string
---@param mode_id string
function M.session_set_mode(session_id, mode_id)
  return M.request("session/set_mode", { sessionId = session_id, modeId = mode_id })
end

--- session/set_config_option
---@param session_id string
---@param config_id string
---@param value string
function M.session_set_config_option(session_id, config_id, value)
  return M.request("session/set_config_option", { sessionId = session_id, configId = config_id, value = value })
end

-- ── Client → Agent responses (called by the client side) ────────────────────

--- Respond to session/request_permission
---@param id integer|string
---@param outcome "selected"|"cancelled"
---@param option_id? string  required when outcome == "selected"
function M.respond_permission(id, outcome, option_id)
  local o = { outcome = outcome }
  if outcome == "selected" then o.optionId = option_id end
  return M.respond(id, { outcome = o })
end

--- Respond to fs/read_text_file
---@param id integer|string
---@param content string
function M.respond_read_file(id, content)
  return M.respond(id, { content = content })
end

--- Respond to fs/write_text_file
---@param id integer|string
function M.respond_write_file(id)
  return M.respond(id, {})
end

--- Respond to terminal/* requests
---@param id integer|string
---@param result table
function M.respond_terminal(id, result)
  return M.respond(id, result)
end

-- ── ContentBlock helpers ─────────────────────────────────────────────────────

M.content = {}

---@param text string
function M.content.text(text)
  return { type = "text", text = text }
end

---@param uri string
---@param name string
---@param mime_type? string
function M.content.resource_link(uri, name, mime_type)
  return { type = "resource_link", uri = uri, name = name, mimeType = mime_type }
end

---@param uri string
---@param text string
---@param mime_type? string
function M.content.resource(uri, text, mime_type)
  return { type = "resource", resource = { uri = uri, text = text, mimeType = mime_type } }
end

-- ── Capability registry ──────────────────────────────────────────────────────

local _capabilities = {}

--- Register a handler for one or more methods.
--- Single:  M.capability("fs/read_text_file", fn)
--- Bulk:    M.capability({ ["fs/read_text_file"] = fn, ... })
---@param method string|table<string, function>
---@param handler? function
function M.capability(method, handler)
  if type(method) == "table" then
    for k, v in pairs(method) do _capabilities[k] = v end
  else
    _capabilities[method] = handler
  end
end

-- ── Dispatcher ───────────────────────────────────────────────────────────────

--- Dispatch an incoming message.
--- `handlers` (optional) takes priority over the capability registry.
--- keys: method names, "response", "error"
---@param msg table
---@param handlers? table<string, function>
function M.dispatch(msg, handlers)
  handlers = handlers or {}
  if M.is_response(msg) then
    local h = handlers[msg.error and "error" or "response"] or _capabilities[msg.error and "error" or "response"]
    if h then h(msg.id, msg.error or msg.result) end
  elseif msg.method then
    local h = handlers[msg.method] or _capabilities[msg.method]
    if h then
      h(msg.id, msg.params)
    elseif M.is_request(msg) then
      return M.error_response(msg.id, M.errors.METHOD_NOT_FOUND, "method not found: " .. msg.method)
    end
  end
end

return M
