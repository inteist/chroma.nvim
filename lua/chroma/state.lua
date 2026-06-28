---Color picker state machine.
---
---Manages the active color, format, target buffer reference, channel
---selection, and field cursor position.  The state is the central model
---that `render.lua` reads from and `palette.lua` / keymaps write to.

local color = require("chroma.color")
local store = require("chroma.store")
local geo = require("chroma.geometry")
local hl = require("chroma.highlights")
local input = require("chroma.input")
local util = require("chroma.util")

local notify = util.notify
local copy_to_clipboard = util.copy_to_clipboard

local preview_ns = vim.api.nvim_create_namespace("chroma_preview")

-- ── Module-level state ───────────────────────────────────────────────────────

local config = {
	default_color = "#7cd5ff",
	default_format = "hex",
	format_order = color.formats,
	insert_on_confirm = true,
	live_preview = true,
	store = {},
}

local current_state ---@type ChromaState?

-- ── Config access ────────────────────────────────────────────────────────────

---Return the current configuration table (read-only access for other modules).
---@return table
local function get_config() return config end

-- ── Target location helpers ──────────────────────────────────────────────────

---Locate a color in the current visual selection and narrow the
---replacement region to just the inner arguments when the match is a
---prefixed tuple (e.g. `Color(r, g, b)` → replace only `r, g, b`).
---@return table?
local function locate_visual_target()
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	if start_pos[2] == 0 or end_pos[2] == 0 then
		return nil
	end

	local row1, col1 = start_pos[2] - 1, start_pos[3] - 1
	local row2, col2 = end_pos[2] - 1, end_pos[3]
	if row1 > row2 or (row1 == row2 and col1 > col2) then
		row1, row2 = row2, row1
		col1, col2 = col2 - 1, col1 + 1
	end

	if row1 ~= row2 then
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(0, row1, row1 + 1, false)[1] or ""
	local text = line:sub(col1 + 1, col2)
	local parsed, fmt = color.parse(text)
	if parsed then
		local start_col, end_col, original_text = col1, col2, text
		local span = color.replacement_span(text, fmt)
		if span then
			local leading = #(text:match("^%s*") or "")
			start_col = col1 + leading + span.start_col
			end_col = col1 + leading + span.end_col
			original_text = line:sub(start_col + 1, end_col)
		end
		return {
			buf = vim.api.nvim_get_current_buf(),
			row = row1,
			start_col = start_col,
			end_col = end_col,
			original_text = original_text,
			color = parsed,
			format = fmt,
			replace_mode = span and span.mode or nil,
			replace_suffix_len = span and span.suffix_len or 0,
		}
	end
	return nil
end

---Locate a color literal under the cursor and build a target table.
---When the match includes a replacement span (prefixed tuples), the
---target’s start/end columns point at the inner arguments only.
---@return table?
local function locate_cursor_target()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	row = row - 1
	local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
	local match = color.find_at(line, col)
	if not match then
		return nil
	end
	return {
		buf = buf,
		row = row,
		start_col = match.replace_start_col or match.start_col,
		end_col = match.replace_end_col or match.end_col,
		original_text = match.replace_text or match.text,
		color = match.color,
		format = match.format,
		replace_mode = match.replace_mode,
		replace_suffix_len = match.replace_suffix_len or 0,
	}
end

---Parse a seed value into a color + format, notifying on failure.
---@param value string
---@param fallback_format? string
---@return DotconfigColor? parsed
---@return string? fmt
local function parse_seed(value, fallback_format)
	local parsed, fmt, err = color.parse(value)
	if not parsed then
		notify(err or "Could not parse color", "error")
		return nil, nil
	end
	return parsed, fallback_format or fmt
end

---Return the most recently used color as a seed.
---@return DotconfigColor? color
---@return string? fmt
local function last_recent_seed()
	local recent = store.last_recent()
	if not recent then
		return nil, nil
	end
	local parsed = color.parse(recent.hex)
	if not parsed then
		return nil, nil
	end
	return parsed, parsed.a < 1 and "hexa" or config.default_format
end

---Return a default seed color, preferring the last recent.
---@return DotconfigColor color
---@return string fmt
local function default_seed()
	local recent, recent_fmt = last_recent_seed()
	if recent then
		return recent, recent_fmt
	end
	return color.parse(config.default_color), config.default_format
end

---Resolve the initial color, format, and target from open options.
---@param opts table
---@return DotconfigColor color
---@return string fmt
---@return table? target
local function resolve_initial(opts)
	opts = opts or {}
	if opts.target then
		return opts.target.color, opts.target.format, opts.target
	end

	-- Explicit values come first so `:ColorPicker #ff00ff` and input prompts
	-- always seed the picker with what the user typed, even if the cursor also
	-- happens to be on a different color literal.
	if opts.value then
		local parsed, fmt = parse_seed(opts.value, opts.format)
		if parsed then
			return parsed, fmt, nil
		end
	end

	local target = opts.selection and locate_visual_target() or locate_cursor_target()
	if target then
		return target.color, target.format, target
	end

	if opts.default_color then
		local parsed, fmt = parse_seed(opts.default_color, opts.format or config.default_format)
		if parsed then
			return parsed, fmt, nil
		end
	end

	local parsed, fmt = default_seed()
	return parsed, opts.format or fmt, nil
end

-- ── State class ──────────────────────────────────────────────────────────────

---@class ChromaState
---@field color DotconfigColor
---@field format string
---@field target table?
---@field source_buf number
---@field source_win number
---@field source_pos number[]
---@field channel_index number
---@field field_active boolean
---@field field_cursor table?
---@field field_x number
---@field field_y number
---@field hue number
---@field changed boolean
---@field closed boolean
---@field insert_on_confirm boolean
---@field live_preview boolean
---@field win ChromaWindow?
---@field preview fun()
local State = {}
State.__index = State

---Create a new picker state from the given options.
---@param opts table
---@return ChromaState
function State.new(opts)
	local initial, fmt, target = resolve_initial(opts)
	initial = initial or color.parse(config.default_color)

	local initial_hsv = color.to_hsv(initial)
	local initial_field = geo.color_field_position(initial)
	local self = setmetatable({
		color = color.normalize(initial),
		format = fmt or config.default_format,
		target = target,
		source_buf = vim.api.nvim_get_current_buf(),
		source_win = vim.api.nvim_get_current_win(),
		source_pos = vim.api.nvim_win_get_cursor(0),
		channel_index = 1,
		field_active = true,
		field_cursor = nil,
		field_x = initial_field.x,
		field_y = initial_field.y,
		hue = initial_hsv.h,
		changed = false,
		closed = false,
		insert_on_confirm = opts.insert_on_confirm ~= false and config.insert_on_confirm,
		live_preview = opts.live_preview ~= false and config.live_preview,
	}, State)

	self.preview = util.throttle(function() self:sync_editor_preview() end, 16)

	return self
end

---Whether the picker window is currently open.
---@return boolean
function State:is_open() return self.win and self.win.win and vim.api.nvim_win_is_valid(self.win.win) end

---Format the current color in the active (or given) format.
---@param fmt? string
---@return string
function State:current_text(fmt) return color.format(self.color, fmt or self.format) end

---Format the text that should be written back to the source target.
---
---When the target uses `replace_mode = "args"` (prefixed tuples like
---`Color(...)`), only the inner comma-separated arguments are returned,
---preserving the surrounding wrapper intact in the source buffer.
---@param fmt? string
---@return string
function State:replacement_text(fmt)
	if self.target and self.target.replace_mode == "args" then
		return color.format_args(self.color, fmt or self.format)
	end
	return self:current_text(fmt)
end

---Re-derive the hue from the current RGB color when it carries chroma.
function State:sync_hue_from_color()
	local hsv = color.to_hsv(self.color)
	if hsv.s > 0 and hsv.v > 0 then
		self.hue = hsv.h
	end
end

---Re-derive the color field cursor from the current RGB color.
---
---The field cursor is tracked independently from RGB so low-value rows keep
---their saturation position even when multiple grid cells quantize to the same
---RGB value.
function State:sync_field_from_color()
	local position = geo.color_field_position(self.color)
	self.field_x = position.x
	self.field_y = position.y
end

-- ── Control navigation ───────────────────────────────────────────────────────

---Return the channel definition for the currently selected channel slider,
---or `nil` when the color field is active.
---@return table?
function State:selected_channel()
	if self.field_active then
		return nil
	end
	return color.channel_defs[self.channel_index]
end

---Jump focus to the color field.
function State:select_field()
	self.field_active = true
	self:render()
end

---Jump focus to a specific channel slider by key.
---@param key string
function State:select_channel(key)
	for index, def in ipairs(color.channel_defs) do
		if def.key == key then
			self.field_active = false
			self.channel_index = index
			self:render()
			return
		end
	end
end

---Cycle focus between the color field and channel sliders.
---@param delta? number `1` or `-1`.
function State:next_channel(delta)
	delta = delta or 1
	local count = #color.channel_defs + 1
	local current = self.field_active and 0 or self.channel_index
	local next_index = (current + delta) % count
	self.field_active = next_index == 0
	if not self.field_active then
		self.channel_index = next_index
	end
	self:render()
end

-- ── Color manipulation ───────────────────────────────────────────────────────

---Move the cursor within the color field.
---@param dx? number
---@param dy? number
---@param large? boolean
function State:move_field(dx, dy, large)
	local step = large and 3 or 1
	local x = math.max(1, math.min(geo.COLOR_FIELD_WIDTH, (self.field_x or 1) + (dx or 0) * step))
	local y = math.max(1, math.min(geo.COLOR_FIELD_HEIGHT, (self.field_y or 1) + (dy or 0) * step))
	self.field_active = true
	self:set_color(
		geo.color_field_color(self.hue, x, y, self.color.a),
		nil,
		{ hue = self.hue, field_x = x, field_y = y }
	)
end

---Handle vertical movement: field navigation or channel stepping.
---@param direction number `1` (down) or `-1` (up).
---@param large? boolean
function State:adjust_vertical(direction, large)
	if self.field_active then
		if direction > 0 and (self.field_y or 1) == geo.COLOR_FIELD_HEIGHT then
			self.field_active = false
			self.channel_index = 1
			self:render()
			return
		end
		self:move_field(0, direction, large)
	else
		self:next_channel(direction)
	end
end

---Adjust the active control (field or channel slider).
---@param direction number `1` or `-1`.
---@param large? boolean
function State:adjust(direction, large)
	if self.field_active then
		self:move_field(direction, 0, large)
		return
	end

	local def = self:selected_channel()
	if not def then
		return
	end
	if def.key == "h" then
		local hue = geo.discrete_hue(self.hue, direction, large)
		self:set_color(
			geo.color_field_color(hue, self.field_x or 1, self.field_y or 1, self.color.a),
			nil,
			{ hue = hue, field_x = self.field_x, field_y = self.field_y }
		)
		return
	end
	local step = large and def.large_step or def.step
	self:set_color(color.adjust_channel(self.color, def.key, direction * step))
end

---Set the color to a new value, optionally overriding the format and hue.
---@param value string|DotconfigColor
---@param fmt? string
---@param opts? { hue?: number, field_x?: number, field_y?: number }
function State:set_color(value, fmt, opts)
	opts = opts or {}
	local parsed = type(value) == "table" and color.normalize(value) or color.parse(value)
	if not parsed then
		notify("Could not parse color", "error")
		return
	end
	self.color = parsed
	if opts.hue then
		self.hue = (((opts.hue % 360) + 360) % 360)
	else
		self:sync_hue_from_color()
	end
	if opts.field_x and opts.field_y then
		self.field_x = math.max(1, math.min(geo.COLOR_FIELD_WIDTH, opts.field_x))
		self.field_y = math.max(1, math.min(geo.COLOR_FIELD_HEIGHT, opts.field_y))
	else
		self:sync_field_from_color()
	end
	if fmt then
		self.format = fmt
	end
	self.changed = true
	self:render()
	self.preview()
end

-- ── Format cycling ───────────────────────────────────────────────────────────

---Switch to a specific output format.
---@param fmt string
function State:set_format(fmt)
	if not vim.tbl_contains(config.format_order, fmt) then
		return
	end
	self.format = fmt
	self.changed = true
	self:render()
	self.preview()
end

---Cycle through output formats.
---@param delta? number `1` or `-1`.
function State:cycle_format(delta)
	local current = 1
	for index, fmt in ipairs(config.format_order) do
		if fmt == self.format then
			current = index
			break
		end
	end
	local next_index = ((current - 1 + (delta or 1)) % #config.format_order) + 1
	self:set_format(config.format_order[next_index])
end

-- ── Editor preview ───────────────────────────────────────────────────────────

---Synchronise the inline preview in the source/target buffer.
function State:sync_editor_preview()
	if self.closed then
		return
	end

	-- Branch 1: target exists in the source buffer — update the replacement
	-- region in-place and show a colour swatch extmark after it.
	local target = self.target
	if target and vim.api.nvim_buf_is_valid(target.buf) then
		vim.api.nvim_buf_clear_namespace(target.buf, preview_ns, 0, -1)
		local text = self:replacement_text()
		if self.live_preview and vim.bo[target.buf].modifiable then
			pcall(
				vim.api.nvim_buf_set_text,
				target.buf,
				target.row,
				target.start_col,
				target.row,
				target.end_col,
				{ text }
			)
			target.end_col = target.start_col + #text
		end
		local extmark_col = target.end_col + (target.replace_suffix_len or 0)
		pcall(vim.api.nvim_buf_set_extmark, target.buf, preview_ns, target.row, extmark_col, {
			virt_text = {
				{
					"  " .. color.to_hex(self.color, self.color.a < 1) .. "  ",
					hl.live_swatch_hl(self.color, true, "Editor"),
				},
			},
			virt_text_pos = "inline",
			hl_mode = "combine",
		})
		return
	end

	-- Branch 2: no target — show a virtual text swatch at the cursor
	-- position in the source buffer as a "detached" preview.
	if vim.api.nvim_buf_is_valid(self.source_buf) then
		vim.api.nvim_buf_clear_namespace(self.source_buf, preview_ns, 0, -1)
		pcall(vim.api.nvim_buf_set_extmark, self.source_buf, preview_ns, self.source_pos[1] - 1, self.source_pos[2], {
			virt_text = {
				{ "  " .. self:current_text() .. "  ", hl.live_swatch_hl(self.color, true, "Source") },
			},
			virt_text_pos = "inline",
			hl_mode = "combine",
		})
	end
end

---Clear all inline previews from the source and target buffers.
function State:clear_editor_preview()
	if self.target and vim.api.nvim_buf_is_valid(self.target.buf) then
		vim.api.nvim_buf_clear_namespace(self.target.buf, preview_ns, 0, -1)
	end
	if vim.api.nvim_buf_is_valid(self.source_buf) then
		vim.api.nvim_buf_clear_namespace(self.source_buf, preview_ns, 0, -1)
	end
end

---Restore the original text in the target buffer (undo live preview).
function State:restore_original()
	local target = self.target
	if not (target and self.changed and vim.api.nvim_buf_is_valid(target.buf)) then
		return
	end
	if vim.bo[target.buf].modifiable then
		pcall(
			vim.api.nvim_buf_set_text,
			target.buf,
			target.row,
			target.start_col,
			target.row,
			target.end_col,
			{ target.original_text }
		)
	end
end

-- ── Confirm / Cancel ─────────────────────────────────────────────────────────

---Confirm the current color: write to buffer, save to recents, close window.
function State:confirm()
	-- Use replacement_text() so prefixed tuples only replace the inner args,
	-- leaving the wrapper (e.g. `Color(...)`) intact in the source buffer.
	local text = self:replacement_text()
	self.closed = true
	if self.target and vim.api.nvim_buf_is_valid(self.target.buf) and vim.bo[self.target.buf].modifiable then
		pcall(
			vim.api.nvim_buf_set_text,
			self.target.buf,
			self.target.row,
			self.target.start_col,
			self.target.row,
			self.target.end_col,
			{ text }
		)
		self.target.end_col = self.target.start_col + #text
	end
	self:clear_editor_preview()
	if
		not self.target
		and self.insert_on_confirm
		and vim.api.nvim_buf_is_valid(self.source_buf)
		and vim.bo[self.source_buf].modifiable
	then
		pcall(
			vim.api.nvim_buf_set_text,
			self.source_buf,
			self.source_pos[1] - 1,
			self.source_pos[2],
			self.source_pos[1] - 1,
			self.source_pos[2],
			{ text }
		)
	end
	store.add_recent(self.color)
	if self.win then
		self.win:close()
	end
	current_state = nil
	notify("Applied " .. text)
end

---Cancel the picker: restore original text, close window.
---@param close_window? boolean
function State:cancel(close_window)
	self.closed = true
	self:restore_original()
	self:clear_editor_preview()
	if close_window ~= false and self.win then
		self.win:close()
	end
	current_state = nil
	notify("Color change cancelled", "warn")
end

-- ── Copy actions ─────────────────────────────────────────────────────────────

---Copy the current color in the active (or given) format.
---@param fmt? string
function State:copy(fmt)
	local text = self:current_text(fmt)
	copy_to_clipboard(text)
	store.add_recent(self.color)
	notify("Copied " .. text)
end

---Copy all format representations to the clipboard.
function State:copy_all()
	local lines = {}
	for _, fmt in ipairs(config.format_order) do
		lines[#lines + 1] = color.format_labels[fmt] .. ": " .. color.format(self.color, fmt)
	end
	copy_to_clipboard(table.concat(lines, "\n"))
	store.add_recent(self.color)
	notify("Copied all color formats")
end

-- ── Interactive prompts ──────────────────────────────────────────────────────

---Open an input prompt to type a color value.
function State:prompt_value()
	input.prompt({
		prompt = "Color value",
		default = self:current_text(),
	}, function(value)
		if not value or vim.trim(value) == "" then
			return
		end
		local parsed, fmt, err = color.parse(value)
		if not parsed then
			notify(err or "Could not parse color", "error")
			return
		end
		self:set_color(parsed, fmt)
	end)
end

---Prompt for a palette name + label and save the current color.
function State:prompt_save_palette()
	local default_palette = store.palette_names()[1] or "Custom"
	input.prompt({
		prompt = "Palette name",
		default = default_palette,
	}, function(name)
		if not name or vim.trim(name) == "" then
			return
		end
		input.prompt({
			prompt = "Color label (optional)",
			default = self:current_text("hex"),
		}, function(label)
			store.add_to_palette(name, self.color, label)
			notify(("Saved %s to %s"):format(self:current_text("hex"), name))
		end)
	end)
end

-- ── Render stub ──────────────────────────────────────────────────────────────
-- The actual rendering is in `render.lua`.  This method is overwritten by
-- `render.show()` once the window is created, so calling `self:render()` from
-- state methods correctly routes to the renderer.

---Render stub — replaced by `render.lua` once the window is created.
function State:render() end

-- ── Module API ───────────────────────────────────────────────────────────────

local M = {}

M.State = State

---Return the currently active picker state.
---@return ChromaState?
function M.current() return current_state end

---Set the module-level current state reference.
---@param state ChromaState?
function M.set_current(state) current_state = state end

---Expose target location helpers for other modules.
M.locate_visual_target = locate_visual_target
M.locate_cursor_target = locate_cursor_target

---Expose the default seed for the input prompt.
M.default_seed = default_seed

---Expose the config for read access.
M.get_config = get_config

---Configure the state module.
---@param opts? table
function M.setup(opts) config = vim.tbl_deep_extend("force", config, opts or {}) end

return M
