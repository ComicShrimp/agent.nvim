local M = {}
local acp = require("agent.libs.acp")

--- Send a request and return its id so we can track the response.
local function send(job_id, raw)
	vim.fn.chansend(job_id, raw)
	local msg = vim.json.decode(raw)
	return msg.id
end

local ui = require("agent.ui")

function M.setup()
	vim.api.nvim_create_user_command("AgentSidebar", function()
		ui.open_sidebar()
	end, {})
	vim.api.nvim_create_user_command("AgentFloat", function()
		ui.open_float()
	end, {})

	vim.api.nvim_create_user_command("AgentTest", function(opts)
		local session_id
		local pending = {}
		local chunks = {}
		local ctx = { job_id = nil }

		-- for now using only kiro, because is what I use
		local job_id = vim.fn.jobstart({ "kiro-cli", "acp" }, {
			on_stdout = function(_, data)
				for _, line in ipairs(data) do
					if line == "" then
						goto continue
					end
					vim.notify("ACP raw: " .. line, vim.log.levels.DEBUG)
					local msg, err = acp.parse(line)
					if not msg then
						vim.notify("ACP parse error: " .. err, vim.log.levels.ERROR)
						goto continue
					end

					acp.dispatch(msg, {
						initialize = function(id)
							vim.notify(
								"ACP: unexpected initialize from server id=" .. tostring(id),
								vim.log.levels.DEBUG
							)
						end,

						["session/update"] = function(_, params)
							local u = params and params.update
							if
								u
								and u.sessionUpdate == "agent_message_chunk"
								and u.content
								and u.content.type == "text"
							then
								chunks[#chunks + 1] = u.content.text
							end
						end,

						response = function(id, result)
							local pctx = pending[id]
							vim.notify(
								"ACP: response id=" .. tostring(id) .. " ctx=" .. tostring(pctx),
								vim.log.levels.DEBUG
							)
							pending[id] = nil

							if pctx == "initialize" then
								vim.notify("ACP: initialized, starting session", vim.log.levels.DEBUG)
								local rid = send(ctx.job_id, acp.session_new(vim.fn.getcwd()))
								pending[rid] = "session_new"
							elseif pctx == "session_new" then
								session_id = result.sessionId
								vim.notify("ACP: session_id=" .. tostring(session_id), vim.log.levels.DEBUG)
								local rid = send(
									ctx.job_id,
									acp.session_prompt(session_id, {
										acp.content.text(opts.args),
									})
								)
								pending[rid] = "prompt"
							elseif pctx == "prompt" then
								vim.notify(table.concat(chunks, ""), vim.log.levels.INFO)
								vim.fn.jobstop(ctx.job_id)
							end
						end,

						error = function(_, e)
							vim.notify("ACP error: " .. e.message, vim.log.levels.ERROR)
							vim.fn.jobstop(ctx.job_id)
						end,
					})

					::continue::
				end
			end,
			on_stderr = function(_, data)
				for _, line in ipairs(data) do
					if line ~= "" then
						vim.notify("ACP stderr: " .. line, vim.log.levels.WARN)
					end
				end
			end,
			on_exit = function(_, code)
				vim.notify("ACP: job exited code=" .. tostring(code), vim.log.levels.DEBUG)
			end,
		})

		ctx.job_id = job_id
		vim.notify("ACP: job_id=" .. tostring(job_id), vim.log.levels.DEBUG)
		local rid = send(job_id, acp.initialize(1, { name = "nvim-test", version = "0.1" }))
		pending[rid] = "initialize"
	end, { nargs = "+" })
end

return M
