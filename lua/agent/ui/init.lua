local M = {}
local chat = require("agent.ui.chat")

M.on_send = nil
M.on_cancel = nil

M.state = {
	sidebar = { chat_buf = nil, input_buf = nil, chat_win = nil, input_win = nil },
	float   = { chat_buf = nil, input_buf = nil, chat_win = nil, input_win = nil },
}

-- re-export chat helpers so callers only need to require ui
M.append_message = chat.append_message
M.start_thinking  = chat.start_thinking

local function is_open(s)
	return s.chat_win and vim.api.nvim_win_is_valid(s.chat_win)
end

local function make_chat_buf()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden  = "wipe"
	vim.bo[buf].filetype   = "markdown"
	return buf
end

local function make_input_buf()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buftype   = "nofile"
	return buf
end

local function bind_send(s)
	vim.keymap.set({ "n", "i" }, "<CR>", function()
		local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(s.input_buf, 0, -1, false), "\n"))
		if text == "" then return end
		vim.api.nvim_buf_set_lines(s.input_buf, 0, -1, false, { "" })
		chat.append_message(s, "[You]   " .. text)
		if M.on_send then M.on_send(text, s) end
	end, { buffer = s.input_buf, nowait = true })
end

local function win_defaults(win)
	vim.wo[win].wrap           = true
	vim.wo[win].number         = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn     = "no"
	vim.wo[win].winbar         = ""
end

-- Sidebar ---------------------------------------------------------------

function M.open_sidebar()
	local s = M.state.sidebar
	if is_open(s) then
		vim.api.nvim_win_close(s.chat_win, true)
		if s.input_win and vim.api.nvim_win_is_valid(s.input_win) then
			vim.api.nvim_win_close(s.input_win, true)
		end
		return
	end

	s.chat_buf  = make_chat_buf()
	s.input_buf = make_input_buf()

	vim.api.nvim_command("botright vsplit")
	s.chat_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(s.chat_win, s.chat_buf)
	vim.api.nvim_win_set_width(s.chat_win, 50)

	vim.api.nvim_command("belowright split")
	s.input_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(s.input_win, s.input_buf)
	vim.api.nvim_win_set_height(s.input_win, 3)

	win_defaults(s.chat_win)
	win_defaults(s.input_win)
	vim.wo[s.input_win].statusline = "  ✏  Type your message — <Enter> to send"

	bind_send(s)
	vim.cmd("startinsert")
end

-- Float -----------------------------------------------------------------

function M.open_float()
	local s = M.state.float
	if is_open(s) then
		vim.api.nvim_win_close(s.chat_win, true)
		if s.input_win and vim.api.nvim_win_is_valid(s.input_win) then
			vim.api.nvim_win_close(s.input_win, true)
		end
		return
	end

	s.chat_buf  = make_chat_buf()
	s.input_buf = make_input_buf()

	local W       = math.floor(vim.o.columns * 0.6)
	local H       = math.floor(vim.o.lines   * 0.6)
	local row     = math.floor((vim.o.lines   - H) / 2)
	local col     = math.floor((vim.o.columns - W) / 2)
	local input_h = 3
	local chat_h  = H - input_h - 1

	s.chat_win = vim.api.nvim_open_win(s.chat_buf, false, {
		relative = "editor", width = W, height = chat_h,
		row = row, col = col, style = "minimal", border = "rounded",
		title = " Agent Chat ", title_pos = "center",
	})

	s.input_win = vim.api.nvim_open_win(s.input_buf, true, {
		relative = "editor", width = W, height = input_h,
		row = row + chat_h + 1, col = col, style = "minimal", border = "rounded",
		title = " ✏  Message — <Enter> to send ", title_pos = "center",
		footer = " <Esc> close ", footer_pos = "right",
	})

	vim.wo[s.chat_win].wrap  = true
	vim.wo[s.input_win].wrap = true

	local function close()
		if M.on_cancel then M.on_cancel() end
		for _, win in ipairs({ s.chat_win, s.input_win }) do
			if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
		end
	end
	vim.keymap.set("n", "<Esc>", close, { buffer = s.input_buf, nowait = true })
	vim.keymap.set("n", "q",     close, { buffer = s.input_buf, nowait = true })

	bind_send(s)
	vim.cmd("startinsert")
end

return M
