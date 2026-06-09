---Picker window rendering for the color picker.
---
---Owns the Snacks.win lifecycle (creation, keymap wiring) and the
---line-by-line rendering of the color field, channel sliders, format list
---and preview swatch.

local color = require("chroma.color")
local geo = require("chroma.geometry")
local hl_mod = require("chroma.highlights")
local state_mod = require("chroma.state")
local util = require("chroma.util")

local align = util.align
local notify = util.notify

local render_ns = vim.api.nvim_create_namespace("chroma_render")

local M = {}

local CHANNEL_LABEL_WIDTH = 11

-- ── Line building helpers ────────────────────────────────────────────────────

---Append a composed line to the lines + hls arrays.
---@param lines string[]
---@param hls table[]
---@param parts table[] `{ { text, hl_group? }, ... }`
local function add_line(lines, hls, parts)
	local row = #lines
	local text = ""
	for _, part in ipairs(parts) do
		local chunk = part[1] or ""
		local start = #text
		text = text .. chunk
		if part[2] and chunk ~= "" then
			hls[#hls + 1] = { row = row, start_col = start, end_col = #text, hl = part[2] }
		end
	end
	lines[#lines + 1] = text
end

---Compute the display width of a parts array.
---@param parts table[]
---@return number
local function parts_width(parts)
	local width = 0
	for _, part in ipairs(parts) do
		width = width + vim.api.nvim_strwidth(part[1] or "")
	end
	return width
end

---Build a channel label with its shortcut key highlighted.
---@param label string
---@param selected boolean
---@return table[]
local function channel_label_parts(label, selected)
	local shortcut = label:sub(1, 1)
	local rest = label:sub(2)
	local padding = string.rep(" ", math.max(0, CHANNEL_LABEL_WIDTH - vim.api.nvim_strwidth(label)))
	return {
		{ shortcut, "ChromaFooterKey" },
		{ rest .. padding, selected and "ChromaActive" or "ChromaSelectorTitle" },
	}
end

---Add a line with left-aligned and right-aligned part groups.
---@param lines string[]
---@param hls table[]
---@param left table[]
---@param right table[]
---@param width number
local function add_split_line(lines, hls, left, right, width)
	local pad = math.max(1, width - parts_width(left) - parts_width(right))
	local parts = vim.list_extend(vim.deepcopy(left), { { string.rep(" ", pad) } })
	vim.list_extend(parts, right)
	add_line(lines, hls, parts)
end

-- ── Slider + field rendering parts ───────────────────────────────────────────

---Build the hue bar display parts.
---@return table[]
local function hue_slider_parts()
	local parts = {}
	for index, hue in ipairs(geo.hue_sections) do
		local group = ("ChromaHue%03d"):format(index)
		util.set_hl(group, { fg = color.to_hex(color.from_hsl(hue, 100, 50, 1), false) })
		parts[#parts + 1] = { string.rep("█", geo.HUE_SEGMENT_WIDTH), group }
	end
	return parts
end

---Build the hue marker (▼) display parts.
---@param value number Current hue.
---@return table[]
local function hue_marker_parts(value)
	local parts = {}
	local active = geo.nearest_hue_section(value)
	for index, _ in ipairs(geo.hue_sections) do
		parts[#parts + 1] = {
			index == active and "▼" or string.rep(" ", geo.HUE_SEGMENT_WIDTH),
			index == active and "ChromaAccent" or nil,
		}
	end
	return parts
end

---Build parts for a single row of the color field.
---@param state ChromaState
---@param row number 1-based row within the field.
---@return table[]
local function color_field_parts(state, row)
	local parts = {}
	local position = {
		x = state.field_x or geo.color_field_position(state.color).x,
		y = state.field_y or geo.color_field_position(state.color).y,
	}
	for x = 1, geo.COLOR_FIELD_WIDTH do
		local active = x == position.x and row == position.y
		parts[#parts + 1] = {
			active and "◆" or "█",
			hl_mod.color_field_hl(state.hue, x, row, active, state.color.a),
		}
	end
	return parts
end

---Build parts for a channel slider bar.
---@param def table Channel definition.
---@param value number Current channel value.
---@param width number Slider width in cells.
---@param current DotconfigColor
---@return table[]
local function slider_parts(def, value, width, current)
	if def.key == "h" then
		return hue_slider_parts()
	end

	local ratio = def.max == def.min and 0 or (value - def.min) / (def.max - def.min)
	ratio = math.max(0, math.min(1, ratio))
	local fill = math.floor(ratio * width + 0.5)
	local parts = {}
	local rgb_slider = geo.rgb_slider_targets[def.key] ~= nil

	for index = 1, width do
		local segment_ratio = rgb_slider and index / width or (width == 1 and 1 or (index - 1) / (width - 1))
		if index <= fill then
			parts[#parts + 1] = { "█", hl_mod.slider_hl(def, index, segment_ratio, current) }
		else
			parts[#parts + 1] = rgb_slider and { " " } or { "░", "ChromaBarEmpty" }
		end
	end

	return parts
end

-- ── Footer ───────────────────────────────────────────────────────────────────

local function picker_footer()
	-- cspell: disable
	return {
		{ " ", "ChromaFooter" },
		{ " hjkl/arrows ", "ChromaFooterKey" },
		{ "=adjust ", "ChromaFooterDesc" },
		{ " tab ", "ChromaFooterKey" },
		{ " next ", "ChromaFooterDesc" },
		{ " i", "ChromaFooterKey" },
		{ "nput ", "ChromaFooterDesc" },
		{ " f", "ChromaFooterKey" },
		{ "ormat ", "ChromaFooterDesc" },
		{ " p", "ChromaFooterKey" },
		{ "alette ", "ChromaFooterDesc" },
		{ " y", "ChromaFooterKey" },
		{ "ank ", "ChromaFooterDesc" },
		{ " ", "ChromaFooter" },
	}
	-- cspell: enable
end

-- ── Main render ──────────────────────────────────────────────────────────────

---Build the complete buffer model for the picker window.
---@param state ChromaState
---@return string[] lines
---@return table[] hls
local function build_model(state)
	hl_mod.ensure()
	local cfg = state_mod.get_config()
	local lines = {}
	local hls = {}
	local swatch = hl_mod.live_swatch_hl(state.color, false, "Current")
	local text_swatch = hl_mod.live_swatch_hl(state.color, true, "CurrentText")
	local target_label = state.target and "live replacement" or "insert on confirm"
	local preview = { { string.rep("█", geo.PREVIEW_WIDTH), swatch } }
	local hex_preview = { { " " .. color.to_hex(state.color, state.color.a < 1) .. " ", text_swatch } }
	local format_lines = {
		{
			{ "  " },
			{ "Chroma", "ChromaTitle" },
			{ "  •  " .. target_label, "ChromaMuted" },
		},
		{ { "  Formats", "ChromaTitle" } },
	}

	for _, fmt in ipairs(cfg.format_order) do
		local active = fmt == state.format
		format_lines[#format_lines + 1] = {
			{ "  " },
			{ active and "● " or "○ ", active and "ChromaAccent" or "ChromaMuted" },
			{
				align(color.format_labels[fmt], 13),
				active and "ChromaActive" or "ChromaSelectorTitle",
			},
			{ "  " },
			{ color.format(state.color, fmt), "ChromaValue" },
		}
	end

	for row = 1, 10 do
		add_split_line(lines, hls, format_lines[row] or { { "  " } }, preview, geo.LAYOUT_WIDTH)
	end
	add_split_line(lines, hls, { { "  " } }, { { string.rep(" ", geo.PREVIEW_WIDTH) } }, geo.LAYOUT_WIDTH)
	add_split_line(lines, hls, { { "  " } }, hex_preview, geo.LAYOUT_WIDTH)
	add_line(lines, hls, { { "" } })

	state.field_cursor = nil
	local field_position = {
		x = state.field_x or geo.color_field_position(state.color).x,
		y = state.field_y or geo.color_field_position(state.color).y,
	}
	add_line(lines, hls, {
		{ "  " },
		{
			state.field_active and "▸ " or "  ",
			state.field_active and "ChromaAccent" or "ChromaMuted",
		},
		{
			align("Color Field", 11),
			state.field_active and "ChromaActive" or "ChromaTitle",
		},
		{ "  " },
		{ "hjkl or arrows to adjust saturation", "ChromaMuted" },
	})
	local field_prefix_text = "  " .. "  " .. align("", 11) .. "  "
	for row = 1, geo.COLOR_FIELD_HEIGHT do
		local prefix = { { "  " }, { "  " }, { align("", 11) }, { "  " } }
		local field_row = #lines
		vim.list_extend(prefix, color_field_parts(state, row))
		add_line(lines, hls, prefix)
		if row == field_position.y then
			state.field_cursor = {
				row = field_row,
				col = #field_prefix_text + ((field_position.x - 1) * #"█"),
			}
		end
	end

	add_line(lines, hls, { { "" } })
	add_line(lines, hls, {
		{ "  Channels", "ChromaTitle" },
		{ "  (hjkl or arrows to adjust values)", "ChromaMuted" },
	})
	for index, def in ipairs(color.channel_defs) do
		local value = def.key == "h" and state.hue or color.channel_value(state.color, def.key)
		local selected = not state.field_active and index == state.channel_index
		if def.key == "h" then
			local marker = { { "  " }, { "  " }, { align("", 11) }, { "  " } }
			vim.list_extend(marker, hue_marker_parts(value))
			add_line(lines, hls, marker)
		end
		local parts = {
			{ "  " },
			{ selected and "▸ " or "  ", selected and "ChromaAccent" or "ChromaMuted" },
		}
		vim.list_extend(parts, channel_label_parts(def.label, selected))
		vim.list_extend(parts, {
			{ "  " },
		})
		vim.list_extend(parts, slider_parts(def, value, geo.CHANNEL_SLIDER_WIDTH, state.color))
		vim.list_extend(parts, {
			{ "  " },
			{
				align(math.floor(value + 0.5) .. def.unit, 6),
				selected and "ChromaAccent" or "ChromaValue",
			},
		})
		add_line(lines, hls, parts)
	end
	return lines, hls
end

---Flush the rendered model into the picker buffer.
---@param state ChromaState
local function render(state)
	if not (state.win and state.win.buf and vim.api.nvim_buf_is_valid(state.win.buf)) then
		return
	end
	local lines, hls = build_model(state)
	vim.bo[state.win.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.win.buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(state.win.buf, render_ns, 0, -1)
	for _, h in ipairs(hls) do
		vim.api.nvim_buf_add_highlight(state.win.buf, render_ns, h.hl, h.row, h.start_col, h.end_col)
	end
	vim.bo[state.win.buf].modifiable = false
	if state.field_cursor and state.win.win and vim.api.nvim_win_is_valid(state.win.win) then
		pcall(vim.api.nvim_win_set_cursor, state.win.win, { state.field_cursor.row + 1, state.field_cursor.col })
	end
	state.win:set_title("󰏘  Chroma", "center")
end

-- ── Window creation ──────────────────────────────────────────────────────────

---Create and show the picker window for the given state.
---@param state ChromaState
function M.show(state)
	local snacks = util.get_snacks()
	if not (snacks and snacks.win) then
		notify("Snacks.win is not available", "error")
		return
	end

	-- Lazy-load palette module to avoid circular requires at file load time.
	local palette = require("chroma.palette")

	state_mod.set_current(state)

	-- Wire the render method into the state so `state:render()` works.
	function state:render() render(self) end

	state.win = snacks.win.new({
		style = "color_picker",
		show = false,
		text = { "" },
		ft = "chroma",
		height = geo.PICKER_HEIGHT,
		footer = picker_footer(),
		keys = {
			q = { function() state:cancel() end, desc = "Cancel" },
			["<esc>"] = { function() state:cancel() end, desc = "Cancel" },
			["<cr>"] = { function() state:confirm() end, desc = "Apply" },
			h = { function() state:adjust(-1) end, desc = "Left / Decrease" },
			l = { function() state:adjust(1) end, desc = "Right / Increase" },
			j = { function() state:adjust_vertical(1) end, desc = "Down / Next" },
			k = { function() state:adjust_vertical(-1) end, desc = "Up / Previous" },
			["<left>"] = { function() state:adjust(-1) end, desc = "Left / Decrease" },
			["<right>"] = { function() state:adjust(1) end, desc = "Right / Increase" },
			["<down>"] = { function() state:adjust_vertical(1) end, desc = "Down / Next" },
			["<up>"] = { function() state:adjust_vertical(-1) end, desc = "Up / Previous" },
			["<s-left>"] = { function() state:adjust(-1, true) end, desc = "Left ×3 / Decrease ×10" },
			["<s-right>"] = { function() state:adjust(1, true) end, desc = "Right ×3 / Increase ×10" },
			["<s-down>"] = { function() state:adjust_vertical(1, true) end, desc = "Down ×3" },
			["<s-up>"] = { function() state:adjust_vertical(-1, true) end, desc = "Up ×3" },
			["-"] = { function() state:adjust(-1, true) end, desc = "Decrease ×10" },
			["+"] = { function() state:adjust(1, true) end, desc = "Increase ×10" },
			["<tab>"] = { function() state:next_channel(1) end, desc = "Next Control" },
			["<s-tab>"] = { function() state:next_channel(-1) end, desc = "Previous Control" },
			c = { function() state:select_field() end, desc = "Color Field" },
			H = { function() state:select_channel("h") end, desc = "Hue" },
			S = { function() state:select_channel("s") end, desc = "Saturation" },
			L = { function() state:select_channel("l") end, desc = "Lightness" },
			R = { function() state:select_channel("r") end, desc = "Red" },
			G = { function() state:select_channel("g") end, desc = "Green" },
			B = { function() state:select_channel("b") end, desc = "Blue" },
			A = { function() state:select_channel("a") end, desc = "Alpha" },
			f = { function() state:cycle_format(1) end, desc = "Next Format" },
			F = { function() state:cycle_format(-1) end, desc = "Previous Format" },
			i = { function() state:prompt_value() end, desc = "Input Color" },
			a = { function() state:prompt_save_palette() end, desc = "Save Palette" },
			p = { function() palette.open({ state = state }) end, desc = "Palettes" },
			r = { function() palette.open({ state = state, recents_only = true }) end, desc = "Recents" },
			y = { function() state:copy() end, desc = "Copy" },
			Y = { function() state:copy_all() end, desc = "Copy All" },
			["?"] = { function(win) win:toggle_help({ col_width = 18, key_width = 12 }) end, desc = "Help" },
		},
		on_close = function()
			if state_mod.current() == state and not state.closed then
				state:cancel(false)
			end
		end,
	})
	state.win:show()
	render(state)
	state:sync_editor_preview()
end

return M
