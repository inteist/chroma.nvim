---Color field and slider geometry for the color picker.
---
---Owns the constants (field dimensions, hue sections, slider widths) and the
---pure-math functions that map between pixel positions and color values.
---Extracting this from `ui.lua` eliminates the confusing forward-declaration
---pattern where `local` variables were declared as `nil` then reassigned as
---functions further down in the file.

local color = require("chroma.color")
local util = require("chroma.util")

local M = {}

-- ── Constants ────────────────────────────────────────────────────────────────

M.HUE_SEGMENT_WIDTH = 1
M.HUE_SECTION_COUNT = 60
M.CHANNEL_SLIDER_WIDTH = M.HUE_SEGMENT_WIDTH * M.HUE_SECTION_COUNT
M.COLOR_FIELD_WIDTH = M.CHANNEL_SLIDER_WIDTH
M.COLOR_FIELD_HEIGHT = 12

---Layout constants used by the rendering module.
M.LAYOUT_WIDTH = 90
M.PREVIEW_WIDTH = 24
M.PICKER_HEIGHT = M.COLOR_FIELD_HEIGHT + 24
M.PALETTE_WIDTH = 82

---Pre-computed hue section boundaries for the discrete hue slider.
---@type number[]
M.hue_sections = {}
for i = 1, M.HUE_SECTION_COUNT do
	M.hue_sections[i] = math.floor(((i - 1) * 360 / M.HUE_SECTION_COUNT) + 0.5)
end

---RGB targets for the simple red/green/blue channel sliders.
M.rgb_slider_targets = {
	r = { r = 255, g = 0, b = 0, a = 1 },
	g = { r = 0, g = 255, b = 0, a = 1 },
	b = { r = 0, g = 0, b = 255, a = 1 },
}

-- ── Hue helpers ──────────────────────────────────────────────────────────────

---Compute the shortest angular distance between two hue values.
---@param a number
---@param b number
---@return number
function M.hue_distance(a, b)
	local distance = math.abs((((a - b) % 360) + 360) % 360)
	return math.min(distance, 360 - distance)
end

---Return the 1-based index of the hue section nearest to `value`.
---@param value number
---@return number
function M.nearest_hue_section(value)
	local hue = (((tonumber(value) or 0) % 360) + 360) % 360
	local nearest = 1
	local nearest_distance = math.huge
	for index, section in ipairs(M.hue_sections) do
		local distance = M.hue_distance(hue, section)
		if distance < nearest_distance then
			nearest = index
			nearest_distance = distance
		end
	end
	return nearest
end

---Step the hue to the next discrete section.
---@param value number Current hue.
---@param direction number `1` or `-1`.
---@param large? boolean Use a larger step (2 sections instead of 1).
---@return number hue
function M.discrete_hue(value, direction, large)
	local index = M.nearest_hue_section(value)
	local step = large and 2 or 1
	index = ((index - 1 + (direction > 0 and step or -step)) % #M.hue_sections) + 1
	return M.hue_sections[index]
end

-- ── Color field ──────────────────────────────────────────────────────────────

---Map a color to its (x, y) position in the color field grid.
---@param c DotconfigColor
---@return { x: number, y: number, hsv: table }
function M.color_field_position(c)
	local hsv = color.to_hsv(c)
	local x = math.floor((hsv.s / 100) * (M.COLOR_FIELD_WIDTH - 1) + 0.5) + 1
	local y = math.floor(((100 - hsv.v) / 100) * (M.COLOR_FIELD_HEIGHT - 1) + 0.5) + 1
	return {
		x = math.max(1, math.min(M.COLOR_FIELD_WIDTH, x)),
		y = math.max(1, math.min(M.COLOR_FIELD_HEIGHT, y)),
		hsv = hsv,
	}
end

---Compute the color at a given (x, y) position in the color field.
---@param hue number
---@param x number
---@param y number
---@param alpha? number
---@return DotconfigColor
function M.color_field_color(hue, x, y, alpha)
	local saturation = M.COLOR_FIELD_WIDTH == 1 and 100 or ((x - 1) / (M.COLOR_FIELD_WIDTH - 1)) * 100
	local value = M.COLOR_FIELD_HEIGHT == 1 and 100 or (1 - ((y - 1) / (M.COLOR_FIELD_HEIGHT - 1))) * 100
	return color.from_hsv(hue or 0, saturation, value, alpha)
end

-- ── Slider math ──────────────────────────────────────────────────────────────

---Linearly blend a single channel between a foreground and background color.
---@param fg table
---@param bg table
---@param amount number 0..1
---@param key string `"r"`, `"g"`, or `"b"`.
---@return number
function M.blend_channel(fg, bg, amount, key)
	return math.floor(bg[key] + (fg[key] - bg[key]) * amount + 0.5)
end

---Return the slider background color derived from the active theme.
---@return DotconfigColor
function M.slider_background()
	return color.parse(util.theme_color("NormalFloat", "bg", util.theme_color("Normal", "bg", "#161616")))
		or { r = 22, g = 22, b = 22, a = 1 }
end

---Compute the hex color for a single slider segment.
---@param def table Channel definition from `color.channel_defs`.
---@param ratio number 0..1 position along the slider.
---@param current DotconfigColor The current color value.
---@return string hex
function M.slider_color(def, ratio, current)
	ratio = math.max(0, math.min(1, ratio))

	local rgb_target = M.rgb_slider_targets[def.key]
	if rgb_target then
		local bg = M.slider_background()
		return color.to_hex({
			r = M.blend_channel(rgb_target, bg, ratio, "r"),
			g = M.blend_channel(rgb_target, bg, ratio, "g"),
			b = M.blend_channel(rgb_target, bg, ratio, "b"),
			a = 1,
		}, false)
	end

	local hsl = color.to_hsl(current)
	if def.key == "h" then
		return color.to_hex(color.from_hsl(ratio * 360, 100, 50, current.a), false)
	elseif def.key == "s" then
		return color.to_hex(color.from_hsl(hsl.h, ratio * 100, math.max(30, math.min(70, hsl.l)), current.a), false)
	elseif def.key == "l" then
		return color.to_hex(color.from_hsl(hsl.h, math.max(1, hsl.s), ratio * 100, current.a), false)
	elseif def.key == "a" then
		local bg = M.slider_background()
		local fg = color.normalize(current)
		return color.to_hex({
			r = M.blend_channel(fg, bg, ratio, "r"),
			g = M.blend_channel(fg, bg, ratio, "g"),
			b = M.blend_channel(fg, bg, ratio, "b"),
			a = 1,
		}, false)
	end

	return color.to_hex(current, false)
end

return M
