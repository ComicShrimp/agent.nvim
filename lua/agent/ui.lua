local M = {}

local state = {
	sidebar = { chat_buf = nil, input_buf = nil, chat_win = nil, input_win = nil },
	float = { chat_buf = nil, input_buf = nil, chat_win = nil, input_win = nil },
}

M.state = state

-- Callback set by init.lua
M.on_send = nil

local function is_open(s)
	return s.chat_win and vim.api.nvim_win_is_valid(s.chat_win)
end

local function make_chat_buf()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	return buf
end

local function make_input_buf()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype = "nofile"
	return buf
end

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Show a spinning "thinking" indicator. Returns a function to stop it and replace with final text.
function M.start_thinking(s)
	local buf = s.chat_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return function() end end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "[Agent] ⠋ thinking…" })
	vim.bo[buf].modifiable = false
	local line = vim.api.nvim_buf_line_count(buf) -- 1-indexed

	local frame = 1
	local timer = vim.uv.new_timer()
	if not timer then return function() end end
	timer:start(120, 120, vim.schedule_wrap(function()
		if not vim.api.nvim_buf_is_valid(buf) then timer:stop() return end
		frame = (frame % #spinner_frames) + 1
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, line - 1, line, false, { "[Agent] " .. spinner_frames[frame] .. " thinking…" })
		vim.bo[buf].modifiable = false
	end))

	return function(reply)
		timer:stop()
		if not vim.api.nvim_buf_is_valid(buf) then return end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, line - 1, line, false, vim.split(reply, "\n", { plain = true }))
		vim.bo[buf].modifiable = false
		if s.chat_win and vim.api.nvim_win_is_valid(s.chat_win) then
			vim.api.nvim_win_set_cursor(s.chat_win, { vim.api.nvim_buf_line_count(buf), 0 })
		end
	end
end

--- Append a message line to a chat buffer.
function M.append_message(s, text)
	local buf = s.chat_buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
	vim.bo[buf].modifiable = true
	local lines = vim.split(text, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
	vim.bo[buf].modifiable = false
	-- scroll to bottom
	if s.chat_win and vim.api.nvim_win_is_valid(s.chat_win) then
		local line_count = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_win_set_cursor(s.chat_win, { line_count, 0 })
	end
end

local function bind_send(s)
	vim.keymap.set({ "n", "i" }, "<CR>", function()
		local lines = vim.api.nvim_buf_get_lines(s.input_buf, 0, -1, false)
		local text = vim.trim(table.concat(lines, "\n"))
		if text == "" then return end
		vim.api.nvim_buf_set_lines(s.input_buf, 0, -1, false, { "" })
		M.append_message(s, "[You]   " .. text)
		if M.on_send then M.on_send(text, s) end
	end, { buffer = s.input_buf, nowait = true })
end

-- Sidebar ---------------------------------------------------------------

function M.open_sidebar()
	if is_open(state.sidebar) then
		vim.api.nvim_win_close(state.sidebar.chat_win, true)
		if state.sidebar.input_win and vim.api.nvim_win_is_valid(state.sidebar.input_win) then
			vim.api.nvim_win_close(state.sidebar.input_win, true)
		end
		return
	end

	local s = state.sidebar
	s.chat_buf = make_chat_buf()
	s.input_buf = make_input_buf()

	-- chat window (right split)
	vim.api.nvim_command("botright vsplit")
	s.chat_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(s.chat_win, s.chat_buf)
	vim.api.nvim_win_set_width(s.chat_win, 50)

	-- input window (split below chat)
	vim.api.nvim_set_current_win(s.chat_win)
	vim.api.nvim_command("belowright split")
	s.input_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(s.input_win, s.input_buf)
	vim.api.nvim_win_set_height(s.input_win, 3)

	for _, win in ipairs({ s.chat_win, s.input_win }) do
		vim.wo[win].wrap = true
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].winbar = ""
	end

	-- visual hint: statusline label for input window
	vim.wo[s.input_win].statusline = "  ✏  Type your message — <Enter> to send"

	bind_send(s)
	vim.api.nvim_set_current_win(s.input_win)
	vim.cmd("startinsert")
end

-- Float -----------------------------------------------------------------

function M.open_float()
	if is_open(state.float) then
		vim.api.nvim_win_close(state.float.chat_win, true)
		if state.float.input_win and vim.api.nvim_win_is_valid(state.float.input_win) then
			vim.api.nvim_win_close(state.float.input_win, true)
		end
		return
	end

	local s = state.float
	s.chat_buf = make_chat_buf()
	s.input_buf = make_input_buf()

	local total_w = math.floor(vim.o.columns * 0.6)
	local total_h = math.floor(vim.o.lines * 0.6)
	local row = math.floor((vim.o.lines - total_h) / 2)
	local col = math.floor((vim.o.columns - total_w) / 2)
	local input_h = 3
	local chat_h = total_h - input_h - 1 -- 1 for border row between

	s.chat_win = vim.api.nvim_open_win(s.chat_buf, false, {
		relative = "editor",
		width = total_w,
		height = chat_h,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Agent Chat ",
		title_pos = "center",
	})

	s.input_win = vim.api.nvim_open_win(s.input_buf, true, {
		relative = "editor",
		width = total_w,
		height = input_h,
		row = row + chat_h + 1,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " ✏  Message — <Enter> to send ",
		title_pos = "center",
		footer = " <Esc> close ",
		footer_pos = "right",
	})

	for _, win in ipairs({ s.chat_win, s.input_win }) do
		vim.wo[win].wrap = true
	end

	-- close both windows on <Esc> or q (from input)
	local function close_float()
		if M.on_cancel then M.on_cancel() end
		for _, win in ipairs({ s.chat_win, s.input_win }) do
			if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
		end
	end
	vim.keymap.set("n", "<Esc>", close_float, { buffer = s.input_buf, nowait = true })
	vim.keymap.set("n", "q", close_float, { buffer = s.input_buf, nowait = true })

	bind_send(s)
	vim.cmd("startinsert")
end

return M
