local M = {}

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function buf_write(buf, fn)
	vim.bo[buf].modifiable = true
	fn()
	vim.bo[buf].modifiable = false
end

function M.append_message(s, text)
	local buf = s.chat_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
	buf_write(buf, function()
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(text, "\n", { plain = true }))
	end)
	if s.chat_win and vim.api.nvim_win_is_valid(s.chat_win) then
		vim.api.nvim_win_set_cursor(s.chat_win, { vim.api.nvim_buf_line_count(buf), 0 })
	end
end

function M.start_thinking(s)
	local buf = s.chat_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return function() end end

	buf_write(buf, function()
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "[Agent] ⠋ thinking…" })
	end)
	local line = vim.api.nvim_buf_line_count(buf)

	local frame = 1
	local timer = vim.uv.new_timer()
	if not timer then return function() end end
	timer:start(120, 120, vim.schedule_wrap(function()
		if not vim.api.nvim_buf_is_valid(buf) then timer:stop() return end
		frame = (frame % #spinner_frames) + 1
		buf_write(buf, function()
			vim.api.nvim_buf_set_lines(buf, line - 1, line, false, { "[Agent] " .. spinner_frames[frame] .. " thinking…" })
		end)
	end))

	return function(reply)
		timer:stop()
		if not vim.api.nvim_buf_is_valid(buf) then return end
		buf_write(buf, function()
			vim.api.nvim_buf_set_lines(buf, line - 1, line, false, vim.split(reply, "\n", { plain = true }))
		end)
		if s.chat_win and vim.api.nvim_win_is_valid(s.chat_win) then
			vim.api.nvim_win_set_cursor(s.chat_win, { vim.api.nvim_buf_line_count(buf), 0 })
		end
	end
end

return M
