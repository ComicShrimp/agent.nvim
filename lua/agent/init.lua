local M = {}

function M.setup(opts)
	local cmd = (opts and opts.cmd) or { "kiro-cli", "acp" }

	local ui = require("agent.ui")
	local client = require("agent.client")

	local send, cancel = client.new(cmd)
	ui.on_send = send
	ui.on_cancel = cancel

	vim.api.nvim_create_user_command("AgentSidebar", ui.open_sidebar, {})
	vim.api.nvim_create_user_command("AgentFloat", ui.open_float, {})

	vim.api.nvim_create_user_command("AgentFixDiagnostic", function()
		local diags = vim.diagnostic.get(0, { lnum = vim.api.nvim_win_get_cursor(0)[1] - 1 })
		if #diags == 0 then
			vim.notify("No diagnostics under cursor", vim.log.levels.WARN)
			return
		end
		local d = diags[1]
		local lnum = d.lnum + 1
		local bufnr = vim.api.nvim_get_current_buf()
		local file = vim.api.nvim_buf_get_name(bufnr)
		local loc = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
		local prompt = ("Can you fix `%s` in file `%s` at line %d:\n```\n%s\n```"):format(d.message, file, lnum, loc)

		-- use sidebar if open, otherwise open float
		local s
		if ui.state.sidebar.chat_win and vim.api.nvim_win_is_valid(ui.state.sidebar.chat_win) then
			s = ui.state.sidebar
		else
			ui.open_float()
			s = ui.state.float
		end

		ui.append_message(s, "[You]   " .. prompt)
		send(prompt, s, function()
			vim.cmd("checktime " .. bufnr)
		end)
	end, {})
end

return M
