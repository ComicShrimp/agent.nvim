local M = {}
local acp = require("agent.libs.acp")
local ui = require("agent.ui")

local config = {
	cmd = { "kiro-cli", "acp" },
}

local function send(job_id, raw)
	vim.fn.chansend(job_id, raw)
	return vim.json.decode(raw).id
end

local function make_acp_sender()
	local session_id
	local pending = {}
	local ctx = { job_id = nil }

	local function cancel()
		if ctx.job_id and session_id then
			vim.fn.chansend(ctx.job_id, acp.session_cancel(session_id))
			local pctx = pending["stream"]
			if pctx and pctx.done then
				pending["stream"] = nil
				pctx.done("[Agent] ✗ Cancelled")
			end
		end
	end

	local function start(text, s, on_done)
		local chunks = {}

		if ctx.job_id then
			if session_id then
				local rid = send(ctx.job_id, acp.session_prompt(session_id, { acp.content.text(text) }))
				local pctx = { kind = "prompt", s = s, chunks = chunks, done = ui.start_thinking(s), on_done = on_done }
				pending[rid] = pctx
				pending["stream"] = pctx
			end
			return
		end

		local job_id = vim.fn.jobstart(config.cmd, {
			on_stdout = function(_, data)
				for _, line in ipairs(data) do
					if line == "" then goto continue end
					local msg, err = acp.parse(line)
					if not msg then
						vim.notify("ACP parse error: " .. err, vim.log.levels.ERROR)
						goto continue
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
						["fs/read_text_file"] = function(id, params)
							local path = params and params.path
							local ok, content = pcall(vim.fn.readfile, path)
							if ok then
								vim.fn.chansend(ctx.job_id, acp.respond_read_file(id, table.concat(content, "\n")))
							else
								vim.fn.chansend(ctx.job_id, acp.error_response(id, acp.errors.RESOURCE_NOT_FOUND, "cannot read: " .. tostring(path)))
							end
						end,
						["fs/write_text_file"] = function(id, params)
							local path = params and params.path
							local content = params and params.content or ""
							local ok, err = pcall(vim.fn.writefile, vim.split(content, "\n", { plain = true }), path)
							if ok then
								vim.fn.chansend(ctx.job_id, acp.respond_write_file(id))
								vim.schedule(function()
									for _, buf in ipairs(vim.api.nvim_list_bufs()) do
										if vim.api.nvim_buf_get_name(buf) == path then
											vim.cmd("checktime " .. buf)
										end
									end
								end)
							else
								vim.fn.chansend(ctx.job_id, acp.error_response(id, acp.errors.INTERNAL_ERROR, tostring(err)))
							end
						end,
						["session/request_permission"] = function(id, params)
							local opts = params and params.options or {}
							if #opts == 0 then
								vim.fn.chansend(ctx.job_id, acp.respond_permission(id, "cancelled"))
								return
							end
							local choices = vim.tbl_map(function(o) return o.name or o.optionId end, opts)
							vim.ui.select(choices, { prompt = (params.toolCall and params.toolCall.title) or "Agent permission:" }, function(_, idx)
								if idx then
									vim.fn.chansend(ctx.job_id, acp.respond_permission(id, "selected", opts[idx].optionId))
								else
									vim.fn.chansend(ctx.job_id, acp.respond_permission(id, "cancelled"))
								end
							end)
						end,
						response = function(id, result)
							local pctx = pending[id]
							if not pctx then goto done end
							pending[id] = nil

							if pctx.kind == "initialize" then
								local rid = send(ctx.job_id, acp.session_new(vim.fn.getcwd()))
								pending[rid] = { kind = "session_new", text = pctx.text, s = pctx.s, on_done = pctx.on_done }
							elseif pctx.kind == "session_new" then
								session_id = result.sessionId
								local rid = send(ctx.job_id, acp.session_prompt(session_id, { acp.content.text(pctx.text) }))
								local npctx = { kind = "prompt", s = pctx.s, chunks = chunks, done = ui.start_thinking(pctx.s), on_done = pctx.on_done }
								pending[rid] = npctx
								pending["stream"] = npctx
							elseif pctx.kind == "prompt" then
								pending["stream"] = nil
								local reply = vim.trim(table.concat(pctx.chunks, ""))
								vim.schedule(function()
									pctx.done("[Agent] " .. reply)
									if pctx.on_done then pctx.on_done() end
								end)
							end
							::done::
						end,
						error = function(_, e)
							vim.notify("ACP error: " .. e.message, vim.log.levels.ERROR)
							local pctx = pending["stream"]
							if pctx and pctx.done then
								pending["stream"] = nil
								vim.schedule(function()
									pctx.done("[Agent] ⚠ Error: " .. e.message)
								end)
							end
						end,
					})
					if unhandled then
						vim.fn.chansend(ctx.job_id, unhandled)
					end
					::continue::
				end
			end,
			on_exit = function()
				ctx.job_id = nil
				session_id = nil
			end,
		})

		ctx.job_id = job_id
		local rid = send(job_id, acp.initialize(1, { name = "agent.nvim", version = "0.1" }, { fs = { readTextFile = true, writeTextFile = true }, terminal = false }))
		pending[rid] = { kind = "initialize", text = text, s = s, on_done = on_done }
	end

	return start, cancel
end

local acp_send, acp_cancel = make_acp_sender()
ui.on_send = acp_send
ui.on_cancel = acp_cancel

function M.setup(opts)
	if opts and opts.cmd then
		config.cmd = opts.cmd
	end

	vim.api.nvim_create_user_command("AgentSidebar", ui.open_sidebar, {})
	vim.api.nvim_create_user_command("AgentFloat", ui.open_float, {})

	vim.api.nvim_create_user_command("AgentFixDiagnostic", function()
		local diags = vim.diagnostic.get(0, { lnum = vim.api.nvim_win_get_cursor(0)[1] - 1 })
		if #diags == 0 then
			vim.notify("No diagnostics under cursor", vim.log.levels.WARN)
			return
		end
		local diag = diags[1].message
		local lnum = diags[1].lnum + 1
		local file = vim.api.nvim_buf_get_name(0)
		local bufnr = vim.api.nvim_get_current_buf()
		local loc = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
		local prompt = ("Can you fix `%s` in file `%s` at line %d:\n```\n%s\n```"):format(diag, file, lnum, loc)
		ui.open_float()
		ui.append_message(ui.state.float, "[You]   " .. prompt)
		acp_send(prompt, ui.state.float, function()
			vim.cmd("checktime " .. bufnr)
		end)
	end, {})
end

return M
