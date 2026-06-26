---Small floating-window abstraction used by Chroma.
---
---The project used to rely on a general-purpose UI library for floating
---windows.  Chroma only needs a narrow subset of that API, so this module keeps
---the implementation intentionally small: create a scratch buffer, open a
---centered floating window, install buffer-local keymaps, and provide a compact
---keymap help popup.  Keeping this logic local avoids a large runtime
---dependency while still giving the rendering and palette modules a reusable
---window object.

local M = {}

---@class ChromaWindowKey
---@field [1] string Left-hand side of the mapping.
---@field [2] string|fun(win: ChromaWindow) Right-hand side or callback.
---@field desc? string Human-readable description for `:map` and help popup.
---@field mode? string|string[] Mapping mode. Defaults to normal mode.

---@class ChromaWindow
---@field id number Monotonic id used for augroup/buffer names.
---@field opts table Resolved window options.
---@field keys ChromaWindowKey[] Normalized key specifications.
---@field buf? number Buffer handle owned by the window unless `opts.buf` is set.
---@field win? number Floating window handle.
---@field augroup? number Autocmd group used for lifecycle hooks.
---@field closed boolean Whether the close callback has already been emitted.
---@field private owns_buf boolean Whether this module should wipe `buf` on close.
---@field private backdrop_win? number Backdrop window handle.
---@field private backdrop_buf? number Backdrop buffer handle.
---@field private help_win? number Keymap help window handle.
---@field private help_buf? number Keymap help buffer handle.
local Window = {}
Window.__index = Window

local next_id = 0
local unpack = unpack or table.unpack

local function default_options()
	return {
		position = "float",
		relative = "editor",
		border = "rounded",
		width = 90,
		height = 24,
		zindex = 70,
		enter = true,
		focusable = true,
		backdrop = 60,
		title_pos = "center",
		footer_pos = "center",
		text = { "" },
		keys = {},
		bo = {
			buftype = "nofile",
			bufhidden = "wipe",
			swapfile = false,
		},
		wo = {
			winhighlight = table.concat({
				"Normal:ChromaNormal",
				"NormalNC:ChromaNormal",
				"FloatBorder:ChromaBorder",
				"FloatTitle:ChromaTitle",
				"FloatFooter:ChromaFooter",
				"WinSeparator:ChromaBorder",
			}, ","),
			cursorline = false,
			wrap = false,
		},
	}
end

---Apply local buffer/window options without failing on version-specific keys.
---@param scope "buf"|"win"
---@param handle number
---@param options table?
local function apply_options(scope, handle, options)
	for name, value in pairs(options or {}) do
		local target = {}
		target[scope] = handle
		pcall(vim.api.nvim_set_option_value, name, value, target)
	end
end

---@param value any
---@param min_value number
---@param max_value number
---@return number
local function clamp(value, min_value, max_value)
	return math.max(min_value, math.min(max_value, value))
end

---Resolve an absolute or relative dimension.
---@param self ChromaWindow
---@param value number|fun(win: ChromaWindow):number|nil
---@param total number
---@param fallback number
---@return number
local function resolve_dimension(self, value, total, fallback)
	if type(value) == "function" then
		local ok, result = pcall(value, self)
		value = ok and result or fallback
	end
	value = tonumber(value) or fallback
	if value == 0 then
		return total
	end
	if value > 0 and value < 1 then
		return math.floor(total * value)
	end
	return math.floor(value)
end

---Resolve an absolute, relative, or centered position.
---@param self ChromaWindow
---@param value number|fun(win: ChromaWindow):number|nil
---@param total number
---@param size number
---@return number
local function resolve_position(self, value, total, size)
	if type(value) == "function" then
		local ok, result = pcall(value, self)
		value = ok and result or nil
	end
	if value == nil then
		return math.floor((total - size) / 2)
	end
	value = tonumber(value) or 0
	if value > 0 and value < 1 then
		return math.floor((total - size) * value)
	end
	return math.floor(value)
end

---@param text string|string[]|fun(): string|string[]|nil
---@return string[]
local function normalize_text(text)
	if type(text) == "function" then
		local ok, result = pcall(text)
		text = ok and result or ""
	end
	if type(text) == "string" then
		return vim.split(text, "\n", { plain = true })
	end
	if type(text) == "table" then
		return text
	end
	return { "" }
end

---Normalize user-friendly keymap declarations into a stable list.
---
---Supported forms:
---  * `q = function(win) ... end`
---  * `q = { function(win) ... end, desc = "Close" }`
---  * `q = { "<cmd>close<cr>", desc = "Close" }`
---@param keys table<string, false|string|function|table>?
---@return ChromaWindowKey[]
local function normalize_keys(keys)
	local result = {}
	for lhs, spec in pairs(keys or {}) do
		if spec ~= false then
			local normalized ---@type ChromaWindowKey?
			if type(spec) == "function" then
				normalized = { lhs, spec }
			elseif type(spec) == "string" then
				normalized = { lhs, spec, desc = spec }
			elseif type(spec) == "table" then
				normalized = vim.deepcopy(spec)
				if normalized[1] and not normalized[2] then
					normalized[2] = normalized[1]
					normalized[1] = lhs
				else
					normalized[1] = normalized[1] or lhs
				end
			end
			if normalized and normalized[1] and normalized[2] then
				result[#result + 1] = normalized
			end
		end
	end
	table.sort(result, function(a, b)
		return tostring(a[1]) < tostring(b[1])
	end)
	return result
end

---@param border any
---@return any
local function normalize_border(border)
	if border == true then
		return "rounded"
	end
	if border == false then
		return "none"
	end
	return border or "rounded"
end

---Build the `nvim_open_win` config for a centered floating window.
---@param self ChromaWindow
---@return vim.api.keyset.win_config
local function window_config(self)
	local opts = self.opts
	local columns = math.max(1, vim.o.columns)
	local rows = math.max(1, vim.o.lines - vim.o.cmdheight)
	local width = resolve_dimension(self, opts.width, columns, 90)
	local height = resolve_dimension(self, opts.height, rows, 24)

	if opts.min_width then
		width = math.max(width, opts.min_width)
	end
	if opts.max_width then
		width = math.min(width, opts.max_width)
	end
	if opts.min_height then
		height = math.max(height, opts.min_height)
	end
	if opts.max_height then
		height = math.min(height, opts.max_height)
	end

	width = clamp(width, 1, math.max(1, columns - 2))
	height = clamp(height, 1, math.max(1, rows - 2))

	local config = {
		relative = opts.relative or "editor",
		row = clamp(resolve_position(self, opts.row, rows, height), 0, math.max(0, rows - height)),
		col = clamp(resolve_position(self, opts.col, columns, width), 0, math.max(0, columns - width)),
		width = width,
		height = height,
		style = "minimal",
		border = normalize_border(opts.border),
		zindex = opts.zindex,
		focusable = opts.focusable ~= false,
	}
	if opts.title then
		config.title = opts.title
		config.title_pos = opts.title_pos or "center"
	end
	if opts.footer then
		config.footer = opts.footer
		config.footer_pos = opts.footer_pos or "center"
	end
	return config
end

---Create or reuse the content buffer and seed it with the requested text.
---@param self ChromaWindow
local function ensure_buffer(self)
	if self.opts.buf and vim.api.nvim_buf_is_valid(self.opts.buf) then
		self.buf = self.opts.buf
		self.owns_buf = false
	else
		self.buf = vim.api.nvim_create_buf(false, true)
		self.owns_buf = true
	end

	vim.bo[self.buf].modifiable = true
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, normalize_text(self.opts.text))
	apply_options("buf", self.buf, self.opts.bo)
	if self.opts.ft and vim.bo[self.buf].filetype == "" then
		pcall(vim.api.nvim_set_option_value, "filetype", self.opts.ft, { buf = self.buf })
	end
end

---Open the translucent editor backdrop shown behind modal Chroma windows.
---@param self ChromaWindow
local function open_backdrop(self)
	if self.opts.backdrop == false or self.backdrop_win and vim.api.nvim_win_is_valid(self.backdrop_win) then
		return
	end
	self.backdrop_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[self.backdrop_buf].buftype = "nofile"
	vim.bo[self.backdrop_buf].bufhidden = "wipe"
	vim.bo[self.backdrop_buf].swapfile = false
	pcall(vim.api.nvim_set_hl, 0, "ChromaBackdrop", { bg = "#000000" })
	local ok, win = pcall(vim.api.nvim_open_win, self.backdrop_buf, false, {
		relative = "editor",
		row = 0,
		col = 0,
		width = math.max(1, vim.o.columns),
		height = math.max(1, vim.o.lines - vim.o.cmdheight),
		style = "minimal",
		focusable = false,
		zindex = math.max(1, (self.opts.zindex or 70) - 1),
	})
	if ok then
		self.backdrop_win = win
		vim.wo[win].winblend = tonumber(self.opts.backdrop) or 60
		vim.wo[win].winhighlight = "Normal:ChromaBackdrop"
	else
		pcall(vim.api.nvim_buf_delete, self.backdrop_buf, { force = true })
		self.backdrop_buf = nil
	end
end

---@param win number?
---@return boolean
local function win_valid(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param buf number?
---@return boolean
local function buf_valid(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

function Window:buf_valid()
	return buf_valid(self.buf)
end

function Window:win_valid()
	return win_valid(self.win)
end

function Window:valid()
	return self:buf_valid() and self:win_valid()
end

function Window:_close_help()
	local win, buf = self.help_win, self.help_buf
	self.help_win, self.help_buf = nil, nil
	if win_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if buf_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

function Window:_close_backdrop()
	local win, buf = self.backdrop_win, self.backdrop_buf
	self.backdrop_win, self.backdrop_buf = nil, nil
	if win_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if buf_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

function Window:_delete_buffer(buf)
	buf = buf or self.buf
	if self.owns_buf and buf_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

function Window:_delete_augroup()
	if self.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
		self.augroup = nil
	end
end

function Window:_emit_close()
	if self.closed then
		return
	end
	self.closed = true
	self:_close_help()
	self:_close_backdrop()
	if self.opts.on_close then
		self.opts.on_close(self)
	end
end

---Update the floating-window config and local window options.
---@return ChromaWindow
function Window:update()
	if self:win_valid() then
		pcall(vim.api.nvim_win_set_config, self.win, window_config(self))
		apply_options("win", self.win, self.opts.wo)
	end
	return self
end

---Set or update the border title.
---@param title string|table
---@param pos? "center"|"left"|"right"
---@return ChromaWindow
function Window:set_title(title, pos)
	self.opts.title = title
	self.opts.title_pos = pos or self.opts.title_pos or "center"
	if self:win_valid() then
		pcall(vim.api.nvim_win_set_config, self.win, {
			title = title,
			title_pos = self.opts.title_pos,
		})
	end
	return self
end

---Install all normalized key mappings into the content buffer.
function Window:map()
	if not self:buf_valid() then
		return
	end
	for _, spec in ipairs(self.keys) do
		local rhs = spec[2]
		local map_opts = {
			buffer = self.buf,
			nowait = true,
			silent = true,
			desc = spec.desc,
		}
		local callback = rhs
		if type(rhs) == "function" then
			callback = function()
				return rhs(self)
			end
		end
		vim.keymap.set(spec.mode or "n", spec[1], callback, map_opts)
	end
end

---@param text string
---@param width number
---@return string
local function fit_text(text, width)
	text = tostring(text or "")
	local display_width = vim.api.nvim_strwidth(text)
	if display_width > width then
		return vim.fn.strcharpart(text, 0, math.max(0, width - 1)) .. "…"
	end
	return text .. string.rep(" ", width - display_width)
end

---Build help popup rows from the window's registered mappings.
---@param self ChromaWindow
---@param key_width number
---@param desc_width number
---@return string[]
local function help_lines(self, key_width, desc_width)
	local lines = {}
	for _, spec in ipairs(self.keys) do
		if spec.desc and spec.desc ~= "" then
			lines[#lines + 1] = fit_text(spec[1], key_width) .. "  " .. fit_text(spec.desc, desc_width)
		end
	end
	if #lines == 0 then
		lines[1] = "No keymaps"
	end
	return lines
end

---Toggle a small, non-focusable keymap help window for this Chroma window.
---
---The popup is intentionally simple: it lists the mappings registered through
---this module instead of inspecting every buffer mapping.  That keeps the
---feature deterministic and avoids coupling it to unrelated user keymaps.
---@param opts? { col_width?: number, key_width?: number }
function Window:toggle_help(opts)
	opts = opts or {}
	if win_valid(self.help_win) then
		self:_close_help()
		return
	end

	local key_width = opts.key_width or 10
	local col_width = opts.col_width or 30
	local desc_width = math.max(8, col_width - key_width - 2)
	local lines = help_lines(self, key_width, desc_width)
	local width = math.min(math.max(col_width, 20), math.max(20, vim.o.columns - 4))
	local height = math.min(#lines, math.max(1, vim.o.lines - vim.o.cmdheight - 4))

	self.help_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[self.help_buf].buftype = "nofile"
	vim.bo[self.help_buf].bufhidden = "wipe"
	vim.bo[self.help_buf].swapfile = false
	vim.api.nvim_buf_set_lines(self.help_buf, 0, -1, false, lines)
	self.help_win = vim.api.nvim_open_win(self.help_buf, false, {
		relative = "editor",
		row = math.floor((vim.o.lines - vim.o.cmdheight - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Keymaps ",
		title_pos = "center",
		focusable = false,
		zindex = (self.opts.zindex or 70) + 1,
	})
	vim.wo[self.help_win].winhighlight = self.opts.wo and self.opts.wo.winhighlight or ""

	local close_help = function()
		self:_close_help()
	end
	vim.keymap.set("n", "q", close_help, { buffer = self.help_buf, nowait = true, silent = true, desc = "Close help" })
	vim.keymap.set(
		"n",
		"<esc>",
		close_help,
		{ buffer = self.help_buf, nowait = true, silent = true, desc = "Close help" }
	)
end

---Show the window, creating its buffer/window pair on first use.
---@return ChromaWindow
function Window:show()
	if self:valid() then
		return self:update()
	end

	self.augroup = vim.api.nvim_create_augroup("chroma_window_" .. self.id, { clear = true })
	ensure_buffer(self)
	open_backdrop(self)

	local enter = self.opts.focusable ~= false and self.opts.enter ~= false
	self.win = vim.api.nvim_open_win(self.buf, enter, window_config(self))
	self.closed = false
	apply_options("win", self.win, self.opts.wo)
	for key, value in pairs(self.opts.w or {}) do
		vim.w[self.win][key] = value
	end

	if self.opts.on_buf then
		self.opts.on_buf(self)
	end
	if self.opts.on_win then
		self.opts.on_win(self)
	end
	self:map()

	vim.api.nvim_create_autocmd("WinClosed", {
		group = self.augroup,
		pattern = tostring(self.win),
		callback = function()
			self:_emit_close()
			self.win = nil
			self:_delete_buffer()
			self:_delete_augroup()
		end,
	})

	return self
end

---Close the floating window and wipe owned scratch buffers.
---@return ChromaWindow
function Window:close()
	local win, buf = self.win, self.buf
	self:_emit_close()
	self.win = nil
	if win_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	self:_delete_buffer(buf)
	self:_delete_augroup()
	return self
end

---Create a new Chroma window.
---@param opts? table
---@return ChromaWindow
function M.new(opts)
	next_id = next_id + 1
	local merged = vim.tbl_deep_extend("force", default_options(), opts or {})
	local self = setmetatable({
		id = next_id,
		opts = merged,
		keys = normalize_keys(merged.keys),
		closed = true,
		owns_buf = false,
	}, Window)
	if merged.show ~= false then
		self:show()
	end
	return self
end

M.Window = Window

return M
