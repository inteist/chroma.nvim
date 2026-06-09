local color = require("chroma.color")
local state_mod = require("chroma.state")
local render = require("chroma.render")
local palette = require("chroma.palette")
local highlights = require("chroma.highlights")
local store = require("chroma.store")

local M = {}

M.color = color

local commands_created = false

local function create_user_command(name, callback, opts) pcall(vim.api.nvim_create_user_command, name, callback, opts) end

local function format_complete() return color.formats end

local function default_style()
	return {
		position = "float",
		backdrop = 60,
		border = "rounded",
		width = 90,
		height = 24,
		zindex = 70,
		title_pos = "center",
		footer_pos = "center",
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
		bo = {
			buftype = "nofile",
			bufhidden = "wipe",
			swapfile = false,
		},
	}
end

local function ensure_snacks_style()
	local snacks = require("chroma.util").get_snacks()
	if snacks and snacks.config and snacks.config.styles and not snacks.config.styles.color_picker then
		snacks.config.styles.color_picker = default_style()
	end
end

---Open the interactive color picker.
---@param opts? table
function M.open(opts)
	local state = state_mod.State.new(opts or {})
	render.show(state)
	return state
end

---Open the palette manager.
---@param opts? table
function M.palettes(opts) return palette.open(opts) end

---Prompt for a color string and open it in the picker.
function M.input()
	local snacks = require("chroma.util").get_snacks()
	if not (snacks and snacks.input) then
		require("chroma.util").notify("Snacks input is not available", "error")
		return
	end
	local seed = state_mod.default_seed()
	snacks.input({ prompt = "Color value", default = color.format(seed, "hex") }, function(value)
		if not value or vim.trim(value) == "" then
			return
		end
		M.open({ value = value })
	end)
end

---Open the picker for the color under the cursor or visual selection only.
---@param opts? table
function M.open_under_cursor(opts)
	opts = opts or {}
	local target = opts.selection and state_mod.locate_visual_target() or state_mod.locate_cursor_target()
	if not target then
		require("chroma.util").notify("No color under cursor", "warn")
		return nil
	end
	return M.open(vim.tbl_extend("force", opts, { target = target }))
end

---Copy the color under the cursor or visual selection.
---@param opts? table
function M.copy_under_cursor(opts)
	opts = opts or {}
	local util = require("chroma.util")
	local target = opts.selection and state_mod.locate_visual_target() or state_mod.locate_cursor_target()
	if not target then
		util.notify("No color under cursor", "warn")
		return
	end
	local cfg = state_mod.get_config()
	local fmt = opts.format or target.format or cfg.default_format
	local text = color.format(target.color, fmt)
	util.copy_to_clipboard(text)
	store.add_recent(target.color)
	util.notify("Copied " .. text)
end

---Return the active picker state for advanced user customization.
---@return ChromaState?
function M.current() return state_mod.current() end

---Set highlight groups (re-exported for the ColorScheme autocmd).
M.set_highlights = highlights.set_highlights

---Create ergonomic `:ColorPicker*` commands.
---
---The commands intentionally mirror the keymaps so the feature is discoverable
---from command-line completion and usable in scripts/macros.
local function create_commands()
	if commands_created then
		return
	end
	commands_created = true

	create_user_command(
		"ColorPicker",
		function(cmd)
			M.open({
				value = cmd.args ~= "" and cmd.args or nil,
				selection = cmd.range > 0,
			})
		end,
		{
			nargs = "?",
			range = true,
			desc = "Open Chroma, optionally seeded with a color value",
		}
	)

	create_user_command(
		"ColorPickerInput",
		function() M.input() end,
		{ desc = "Prompt for a color value and open the picker" }
	)

	create_user_command("ColorPickerPalettes", function() M.palettes() end, { desc = "Open saved color palettes" })

	create_user_command("ColorPickerCursor", function(cmd) M.open_under_cursor({ selection = cmd.range > 0 }) end, {
		range = true,
		desc = "Open the color picker for the color under cursor or selection",
	})

	create_user_command(
		"ColorPickerRecents",
		function() M.palettes({ recents_only = true }) end,
		{ desc = "Open recently used colors" }
	)

	create_user_command(
		"ColorPickerCopy",
		function(cmd)
			M.copy_under_cursor({
				selection = cmd.range > 0,
				format = cmd.args ~= "" and cmd.args or nil,
			})
		end,
		{
			nargs = "?",
			range = true,
			complete = format_complete,
			desc = "Copy the color under cursor or selection, optionally converted to a format",
		}
	)
end

---Configure the color picker modules, persistence and user commands.
---@param opts? table
function M.setup(opts)
	opts = opts or {}
	ensure_snacks_style()
	state_mod.setup(opts)
	store.setup(opts.store or {})
	highlights.set_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("Chroma", { clear = true }),
		callback = highlights.set_highlights,
	})
	create_commands()
end

return M
