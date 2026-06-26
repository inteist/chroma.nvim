---Highlight group management for the color picker.
---
---Owns the creation and re-application of all `Chroma*`
---highlight groups, including the per-cell/per-segment dynamic groups used
---by the slider and color field renderers.

local color = require("chroma.color")
local util = require("chroma.util")
local geo = require("chroma.geometry")

local set_hl = util.set_hl

local M = {}

local highlights_ready = false

-- ── Theme-derived highlight groups ───────────────────────────────────────────

---Define Color Picker highlight groups from the active colorscheme.
---
---The groups are reapplied on `ColorScheme` so the picker remains visually
---consistent with the rest of the config while still keeping strong contrast
---for swatches, active controls and key hints.
function M.set_highlights()
	local fg = util.theme_color("Normal", "fg", "#e5e5e5")
	local bg = util.theme_color("NormalFloat", "bg", util.theme_color("Normal", "bg", "#161616"))
	local muted = util.theme_color("Comment", "fg", "#0096f0")
	local accent = util.theme_color("Keyword", "fg", "#e572d3")
	local cyan = util.theme_color("Special", "fg", "#7cd5ff")
	local border = util.theme_color("FloatBorder", "fg", "#3a3a3a")
	local selection = util.theme_color("Visual", "bg", "#2c5b96")

	set_hl("ChromaNormal", { fg = fg, bg = bg })
	set_hl("ChromaBorder", { fg = border, bg = bg })
	set_hl("ChromaTitle", { fg = accent, bg = bg, bold = true })
	set_hl("ChromaSelectorTitle", { fg = "#0096f0", bg = bg, bold = true })
	set_hl("ChromaAccent", { fg = accent, bg = bg, bold = true })
	set_hl("ChromaCyan", { fg = cyan, bg = bg })
	set_hl("ChromaMuted", { fg = muted, bg = bg })
	set_hl("ChromaKey", { fg = bg, bg = accent, bold = true })
	set_hl("ChromaValue", { fg = fg, bg = bg })
	set_hl("ChromaActive", { fg = fg, bg = selection, bold = true })
	set_hl("ChromaBarEmpty", { fg = border, bg = bg })
	set_hl("ChromaFooter", { fg = muted, bg = bg })
	set_hl("ChromaFooterKey", { fg = muted, bg = bg, bold = true })
	set_hl("ChromaFooterDesc", { fg = "#666666", bg = bg })
	set_hl("ChromaBackdrop", { bg = "#000000" })
	highlights_ready = true
end

---Ensure the highlight groups have been created at least once.
function M.ensure()
	if not highlights_ready then
		M.set_highlights()
	end
end

-- ── Per-color swatch highlights ──────────────────────────────────────────────

---Create or update a highlight group for a color swatch.
---@param value string|DotconfigColor
---@param text? boolean Use readable foreground text on the swatch background.
---@return string hl_group
function M.swatch_hl(value, text)
	local parsed = type(value) == "table" and color.normalize(value) or color.parse(value)
	if not parsed then
		return "ChromaMuted"
	end
	local hex = color.to_hex(parsed, false)
	local group = "ChromaSwatch" .. hex:gsub("#", "") .. (text and "Text" or "")
	set_hl(group, text and { fg = color.contrast(parsed), bg = hex, bold = true } or { fg = hex, bg = hex })
	return group
end

---Create a transient swatch highlight for live preview.
---@param value string|DotconfigColor
---@param text? boolean
---@param name? string
---@return string hl_group
function M.live_swatch_hl(value, text, name)
	local parsed = type(value) == "table" and color.normalize(value) or color.parse(value)
	if not parsed then
		return "ChromaMuted"
	end
	local hex = color.to_hex(parsed, false)
	local group = "ChromaLiveSwatch" .. (name or "Current") .. (text and "Text" or "")
	set_hl(group, text and { fg = color.contrast(parsed), bg = hex, bold = true } or { fg = hex, bg = hex })
	return group
end

-- ── Slider + field highlights ────────────────────────────────────────────────

---Create a highlight group for a single slider segment.
---@param def table Channel definition.
---@param index number Segment index (1-based).
---@param ratio number 0..1 position.
---@param current DotconfigColor
---@return string hl_group
function M.slider_hl(def, index, ratio, current)
	local hex = geo.slider_color(def, ratio, current)
	local group = ("ChromaSlider%s%02d"):format(def.key:upper(), index)
	set_hl(group, { fg = hex })
	return group
end

---Create or update a bounded highlight group for a single color field cell.
---
---The group name deliberately excludes hue/color.  Moving across the hue slider
---re-colors the same field grid, so including hue in the name allocates a new
---group for every hue × cell combination and eventually trips Neovim's E849
---highlight-group limit.
---@param hue number
---@param x number
---@param y number
---@param active boolean Whether the cursor is on this cell.
---@param alpha? number
---@return string hl_group
function M.color_field_hl(hue, x, y, active, alpha)
	local field_color = geo.color_field_color(hue, x, y, alpha or 1)
	local hex = color.to_hex(field_color, false)

	if active then
		local group = "ChromaFieldCursor"
		set_hl(group, { fg = color.contrast(field_color), bg = hex, bold = true })
		return group
	end

	local group = ("ChromaField%02d_%03d"):format(y, x)
	set_hl(group, { fg = hex, bg = hex })
	return group
end

return M
