--- ACP client: manages the agent subprocess and session lifecycle.
local M = {}
local acp = require("agent.libs.acp")
local ui  = require("agent.ui")

local function send(job_id, raw)
	vim.fn.chansend(job_id, raw)
	return vim.json.decode(raw).id
end

-- ── FS capability handlers ────────────────────────────────────────────────────

local function handle_read(job_id, id, params)
	local path = params and params.path
	local ok, data = pcall(vim.fn.readfile, path)
	if ok then
		vim.fn.chansend(job_id, acp.respond_read_file(id, table.concat(data, "\n")))
	else
		vim.fn.chansend(job_id, acp.error_response(id, acp.errors.RESOURCE_NOT_FOUND, "cannot read: " .. tostring(path)))
	end
end

local function handle_write(job_id, id, params)
	local path    = params and params.path
	local content = params and params.content or ""
	local ok, err = pcall(vim.fn.writefile, vim.split(content, "\n", { plain = true }), path)
	if ok then
		vim.fn.chansend(job_id, acp.respond_write_file(id))
		vim.schedule(function()
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_get_name(buf) == path then
					vim.cmd("checktime " .. buf)
				end
			end
		end)
	else
		vim.fn.chansend(job_id, acp.error_response(id, acp.errors.INTERNAL_ERROR, tostring(err)))
	end
end

local function handle_permission(job_id, id, params)
	local opts = params and params.options or {}
	if #opts == 0 then
		vim.fn.chansend(job_id, acp.respond_permission(id, "cancelled"))
		return
	end
	local choices = vim.tbl_map(function(o) return o.name or o.optionId end, opts)
	local prompt  = (params.toolCall and params.toolCall.title) or "Agent permission:"
	vim.ui.select(choices, { prompt = prompt }, function(_, idx)
		if idx then
			vim.fn.chansend(job_id, acp.respond_permission(id, "selected", opts[idx].optionId))
		else
			vim.fn.chansend(job_id, acp.respond_permission(id, "cancelled"))
		end
	end)
end

-- ── Session ───────────────────────────────────────────────────────────────────

---@param cmd string[]
---@return function start, function cancel
function M.new(cmd)
	local session_id
	local pending = {}
	local ctx = { job_id = nil }

	local function cancel()
		if not (ctx.job_id and session_id) then return end
		vim.fn.chansend(ctx.job_id, acp.session_cancel(session_id))
		local pctx = pending["stream"]
		if pctx and pctx.done then
			pending["stream"] = nil
			pctx.done("[Agent] ✗ Cancelled")
		end
	end

	local function on_line(line)
		local msg, err = acp.parse(line)
		if not msg then
			vim.notify("ACP parse error: " .. err, vim.log.levels.ERROR)
			return
		end

		local unhandled = acp.dispatch(msg, {
			initialize = function() end,

			["session/update"] = function(_, params)
				local u = params and params.update
				if not u then return end
				if u.sessionUpdate == "agent_message_chunk" and u.content and u.content.type == "text" then
					local pctx = pending["stream"]
					if pctx then pctx.chunks[#pctx.chunks + 1] = u.content.text end
				end
			end,

			["fs/read_text_file"]      = function(id, params) handle_read(ctx.job_id, id, params) end,
			["fs/write_text_file"]     = function(id, params) handle_write(ctx.job_id, id, params) end,
			["session/request_permission"] = function(id, params) handle_permission(ctx.job_id, id, params) end,

			response = function(id, result)
				local pctx = pending[id]
				if not pctx then return end
				pending[id] = nil

				if pctx.kind == "initialize" then
					local rid = send(ctx.job_id, acp.session_new(vim.fn.getcwd()))
					pending[rid] = { kind = "session_new", text = pctx.text, s = pctx.s, on_done = pctx.on_done }

				elseif pctx.kind == "session_new" then
					session_id = result.sessionId
					local chunks = {}
					local rid = send(ctx.job_id, acp.session_prompt(session_id, { acp.content.text(pctx.text) }))
					local npctx = { kind = "prompt", s = pctx.s, chunks = chunks, done = ui.start_thinking(pctx.s), on_done = pctx.on_done }
					pending[rid]        = npctx
					pending["stream"]   = npctx

				elseif pctx.kind == "prompt" then
					pending["stream"] = nil
					local reply = vim.trim(table.concat(pctx.chunks, ""))
					vim.schedule(function()
						pctx.done("[Agent] " .. reply)
						if pctx.on_done then pctx.on_done() end
					end)
				end
			end,

			error = function(_, e)
				vim.notify("ACP error: " .. e.message, vim.log.levels.ERROR)
				local pctx = pending["stream"]
				if pctx and pctx.done then
					pending["stream"] = nil
					vim.schedule(function() pctx.done("[Agent] ⚠ Error: " .. e.message) end)
				end
			end,
		})

		if unhandled then vim.fn.chansend(ctx.job_id, unhandled) end
	end

	local function start(text, s, on_done)
		-- reuse existing job
		if ctx.job_id then
			if session_id then
				local chunks = {}
				local rid = send(ctx.job_id, acp.session_prompt(session_id, { acp.content.text(text) }))
				local pctx = { kind = "prompt", s = s, chunks = chunks, done = ui.start_thinking(s), on_done = on_done }
				pending[rid]      = pctx
				pending["stream"] = pctx
			end
			return
		end

		local job_id = vim.fn.jobstart(cmd, {
			on_stdout = function(_, data)
				for _, line in ipairs(data) do
					if line ~= "" then on_line(line) end
				end
			end,
			on_exit = function()
				ctx.job_id = nil
				session_id = nil
			end,
		})

		ctx.job_id = job_id
		local rid = send(job_id, acp.initialize(1,
			{ name = "agent.nvim", version = "0.1" },
			{ fs = { readTextFile = true, writeTextFile = true }, terminal = false }
		))
		pending[rid] = { kind = "initialize", text = text, s = s, on_done = on_done }
	end

	return start, cancel
end

return M
