local M = {}

-- Shared state
local state = {
	sidebar = { buf = nil, win = nil },
	float = { buf = nil, win = nil },
}

local test_messages = {
	"[Agent] Hello! I'm your AI assistant.",
	"[Agent] I can help you with code, questions, and more.",
	"[You]   What can you do?",
	"[Agent] I can analyze code, answer questions, and assist with tasks via ACP.",
}

local function make_buf(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	return buf
end

local function is_open(s)
	return s.win and vim.api.nvim_win_is_valid(s.win)
end

-- Sidebar

function M.open_sidebar()
	if is_open(state.sidebar) then
		vim.api.nvim_win_close(state.sidebar.win, true)
		return
	end

	local buf = make_buf(test_messages)
	vim.api.nvim_command("botright vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_width(win, 50)
	vim.wo[win].wrap = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"

	state.sidebar = { buf = buf, win = win }
end

-- Float

function M.open_float()
	if is_open(state.float) then
		vim.api.nvim_win_close(state.float.win, true)
		return
	end

	local width = math.floor(vim.o.columns * 0.6)
	local height = math.floor(vim.o.lines * 0.5)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local buf = make_buf(test_messages)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Agent Chat ",
		title_pos = "center",
	})
	vim.wo[win].wrap = true

	state.float = { buf = buf, win = win }

	-- close on <Esc> or q
	for _, key in ipairs({ "<Esc>", "q" }) do
		vim.keymap.set("n", key, function()
			if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
		end, { buffer = buf, nowait = true })
	end
end

return M
