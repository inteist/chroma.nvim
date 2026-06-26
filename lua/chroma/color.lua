---@class DotconfigColor
---@field r number Red channel in the 0-255 range.
---@field g number Green channel in the 0-255 range.
---@field b number Blue channel in the 0-255 range.
---@field a number Alpha channel in the 0-1 range.

local M = {}

M.formats = { "hex", "hexa", "rgb0x", "argb0x", "rgb", "rgba", "hsl", "hsla", "hsv" }

M.format_labels = {
	hex = "HEX",
	hexa = "HEX + Alpha",
	rgb0x = "0x RGB",
	argb0x = "0x ARGB",
	rgb = "RGB",
	rgba = "RGBA",
	hsl = "HSL",
	hsla = "HSLA",
	hsv = "HSV",
}

-- Common CSS color names. The parser intentionally keeps this list compact:
-- it covers the colors people most often type by hand while avoiding a large
-- table in a startup-loaded config module.
M.names = {
	black = "#000000",
	white = "#ffffff",
	red = "#ff0000",
	lime = "#00ff00",
	green = "#008000",
	blue = "#0000ff",
	yellow = "#ffff00",
	cyan = "#00ffff",
	aqua = "#00ffff",
	magenta = "#ff00ff",
	fuchsia = "#ff00ff",
	orange = "#ffa500",
	purple = "#800080",
	pink = "#ffc0cb",
	brown = "#a52a2a",
	gray = "#808080",
	grey = "#808080",
	silver = "#c0c0c0",
	maroon = "#800000",
	olive = "#808000",
	navy = "#000080",
	teal = "#008080",
	transparent = "#00000000",
}

M.channel_defs = {
	{ key = "h", label = "Hue", min = 0, max = 360, step = 1, large_step = 15, unit = "°" },
	{ key = "s", label = "Saturation", min = 0, max = 100, step = 1, large_step = 10, unit = "%" },
	{ key = "l", label = "Lightness", min = 0, max = 100, step = 1, large_step = 10, unit = "%" },
	{ key = "r", label = "Red", min = 0, max = 255, step = 1, large_step = 10, unit = "" },
	{ key = "g", label = "Green", min = 0, max = 255, step = 1, large_step = 10, unit = "" },
	{ key = "b", label = "Blue", min = 0, max = 255, step = 1, large_step = 10, unit = "" },
	{ key = "a", label = "Alpha", min = 0, max = 100, step = 1, large_step = 10, unit = "%" },
}

local function clamp(value, min, max)
	value = tonumber(value) or min
	if value ~= value then
		return min
	end
	if value < min then
		return min
	end
	if value > max then
		return max
	end
	return value
end

local function round(value, places)
	local scale = 10 ^ (places or 0)
	return math.floor(value * scale + 0.5) / scale
end

local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function component_to_hex(value)
	return string.format("%02x", clamp(round(value), 0, 255))
end

local function alpha_to_hex(value)
	return string.format("%02x", clamp(round((value or 1) * 255), 0, 255))
end

local function expand_hex(hex)
	if #hex == 3 or #hex == 4 then
		return (hex:gsub(".", "%0%0"))
	end
	return hex
end

local function parse_hex(value)
	local text = trim(value):lower()
	local hex = text:match("^#?([%da-f]+)$")
	local is_0x = false
	if not hex then
		hex = text:match("^0x([%da-f]+)$")
		is_0x = hex ~= nil
	end
	if not hex then
		return nil
	end

	local valid_length = #hex == 6 or #hex == 8
	if not is_0x then
		valid_length = valid_length or #hex == 3 or #hex == 4
	end
	if not valid_length then
		return nil
	end

	local r, g, b, a, fmt
	if is_0x and #hex == 8 then
		a = tonumber(hex:sub(1, 2), 16) / 255
		r = tonumber(hex:sub(3, 4), 16)
		g = tonumber(hex:sub(5, 6), 16)
		b = tonumber(hex:sub(7, 8), 16)
		fmt = "argb0x"
	else
		hex = expand_hex(hex)
		r = tonumber(hex:sub(1, 2), 16)
		g = tonumber(hex:sub(3, 4), 16)
		b = tonumber(hex:sub(5, 6), 16)
		a = #hex == 8 and (tonumber(hex:sub(7, 8), 16) / 255) or 1
		fmt = is_0x and "rgb0x" or (#hex == 8 and "hexa" or "hex")
	end

	return { r = r, g = g, b = b, a = a }, fmt
end

local function split_args(args)
	args = trim(args):gsub("%s*/%s*", " / ")
	local parts = {}

	if args:find(",") then
		args = args:gsub("%s*/%s*", ",")
		for part in args:gmatch("[^,]+") do
			parts[#parts + 1] = trim(part)
		end
	else
		for part in args:gmatch("%S+") do
			if part ~= "/" then
				parts[#parts + 1] = trim(part)
			end
		end
	end

	return parts
end

local function parse_number(value)
	value = trim(value):lower()
	return tonumber(value:match("[-+]?%d*%.?%d+"))
end

local function parse_alpha(value)
	if value == nil or trim(value) == "" then
		return 1
	end

	local text = trim(value)
	local number = parse_number(text)
	if not number then
		return nil
	end

	if text:find("%%") then
		return clamp(number / 100, 0, 1)
	end

	-- CSS alpha accepts 0-1. Values above 1 are treated as percentages so
	-- `rgba(0, 0, 0, 50)` remains useful when pasted from design tools.
	if number > 1 then
		number = number / 100
	end
	return clamp(number, 0, 1)
end

local function parse_rgb_component(value)
	local text = trim(value)
	local number = parse_number(text)
	if not number then
		return nil
	end

	if text:find("%%") then
		number = number * 255 / 100
	end

	return clamp(round(number), 0, 255)
end

local function parse_hue(value)
	local text = trim(value):lower()
	local number = parse_number(text)
	if not number then
		return nil
	end

	if text:find("turn") then
		number = number * 360
	elseif text:find("rad") then
		number = number * 180 / math.pi
	end

	return ((number % 360) + 360) % 360
end

local function parse_percent(value)
	local text = trim(value)
	local number = parse_number(text)
	if not number then
		return nil
	end

	-- If the user enters normalized values (`hsl(210, .7, .4)`), convert them
	-- to percentages. Explicit `%` values and design-tool values stay as-is.
	if not text:find("%%") and number <= 1 then
		number = number * 100
	end

	return clamp(number, 0, 100)
end

---Normalize a color table into the canonical DotconfigColor shape.
---@param c table
---@return DotconfigColor
function M.normalize(c)
	return {
		r = clamp(round(c.r), 0, 255),
		g = clamp(round(c.g), 0, 255),
		b = clamp(round(c.b), 0, 255),
		a = clamp(c.a == nil and 1 or c.a, 0, 1),
	}
end

---Return a stable lowercase `#rrggbb` string for a color.
---@param c DotconfigColor
---@param include_alpha? boolean Include alpha as `#rrggbbaa`.
---@return string
function M.to_hex(c, include_alpha)
	c = M.normalize(c)
	local hex = "#" .. component_to_hex(c.r) .. component_to_hex(c.g) .. component_to_hex(c.b)
	if include_alpha then
		hex = hex .. alpha_to_hex(c.a)
	end
	return hex
end

---Convert RGB to HSL using the CSS HSL color model.
---@param c DotconfigColor
---@return { h: number, s: number, l: number, a: number }
function M.to_hsl(c)
	c = M.normalize(c)
	local r = c.r / 255
	local g = c.g / 255
	local b = c.b / 255
	local max = math.max(r, g, b)
	local min = math.min(r, g, b)
	local h = 0
	local s = 0
	local l = (max + min) / 2

	if max ~= min then
		local d = max - min
		s = l > 0.5 and d / (2 - max - min) or d / (max + min)
		if max == r then
			h = (g - b) / d + (g < b and 6 or 0)
		elseif max == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h = h / 6
	end

	return { h = round(h * 360, 2), s = round(s * 100, 2), l = round(l * 100, 2), a = c.a }
end

local function hue_to_rgb(p, q, t)
	if t < 0 then
		t = t + 1
	end
	if t > 1 then
		t = t - 1
	end
	if t < 1 / 6 then
		return p + (q - p) * 6 * t
	end
	if t < 1 / 2 then
		return q
	end
	if t < 2 / 3 then
		return p + (q - p) * (2 / 3 - t) * 6
	end
	return p
end

---Convert HSL channels back to RGB.
---@param h number Hue in degrees.
---@param s number Saturation in percent.
---@param l number Lightness in percent.
---@param a? number Alpha in the 0-1 range.
---@return DotconfigColor
function M.from_hsl(h, s, l, a)
	h = (((tonumber(h) or 0) % 360) + 360) % 360 / 360
	s = clamp((tonumber(s) or 0) / 100, 0, 1)
	l = clamp((tonumber(l) or 0) / 100, 0, 1)

	local r, g, b
	if s == 0 then
		r, g, b = l, l, l
	else
		local q = l < 0.5 and l * (1 + s) or l + s - l * s
		local p = 2 * l - q
		r = hue_to_rgb(p, q, h + 1 / 3)
		g = hue_to_rgb(p, q, h)
		b = hue_to_rgb(p, q, h - 1 / 3)
	end

	return M.normalize({ r = r * 255, g = g * 255, b = b * 255, a = a == nil and 1 or a })
end

---Convert RGB to HSV. HSV is useful for palette browsing because it preserves
---a designer-friendly brightness channel.
---@param c DotconfigColor
---@return { h: number, s: number, v: number, a: number }
function M.to_hsv(c)
	c = M.normalize(c)
	local r = c.r / 255
	local g = c.g / 255
	local b = c.b / 255
	local max = math.max(r, g, b)
	local min = math.min(r, g, b)
	local d = max - min
	local h = 0

	if d ~= 0 then
		if max == r then
			h = ((g - b) / d) % 6
		elseif max == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h = h * 60
	end

	local s = max == 0 and 0 or d / max
	return { h = round(h, 2), s = round(s * 100, 2), v = round(max * 100, 2), a = c.a }
end

---Convert HSV channels back to RGB.
---@param h number Hue in degrees.
---@param s number Saturation in percent.
---@param v number Value/brightness in percent.
---@param a? number Alpha in the 0-1 range.
---@return DotconfigColor
function M.from_hsv(h, s, v, a)
	h = (((tonumber(h) or 0) % 360) + 360) % 360
	s = clamp((tonumber(s) or 0) / 100, 0, 1)
	v = clamp((tonumber(v) or 0) / 100, 0, 1)

	local c = v * s
	local x = c * (1 - math.abs((h / 60) % 2 - 1))
	local m = v - c
	local r, g, b = 0, 0, 0

	if h < 60 then
		r, g, b = c, x, 0
	elseif h < 120 then
		r, g, b = x, c, 0
	elseif h < 180 then
		r, g, b = 0, c, x
	elseif h < 240 then
		r, g, b = 0, x, c
	elseif h < 300 then
		r, g, b = x, 0, c
	else
		r, g, b = c, 0, x
	end

	return M.normalize({ r = (r + m) * 255, g = (g + m) * 255, b = (b + m) * 255, a = a == nil and 1 or a })
end

local function parse_rgb(args, fmt)
	local parts = split_args(args)
	if #parts < 3 then
		return nil
	end

	local r = parse_rgb_component(parts[1])
	local g = parse_rgb_component(parts[2])
	local b = parse_rgb_component(parts[3])
	local a = parse_alpha(parts[4])
	if not (r and g and b and a) then
		return nil
	end

	local detected = (fmt == "rgba" or parts[4] ~= nil) and "rgba" or "rgb"
	return M.normalize({ r = r, g = g, b = b, a = a }), detected
end

local function parse_hsl(args, fmt)
	local parts = split_args(args)
	if #parts < 3 then
		return nil
	end

	local h = parse_hue(parts[1])
	local s = parse_percent(parts[2])
	local l = parse_percent(parts[3])
	local a = parse_alpha(parts[4])
	if not (h and s and l and a) then
		return nil
	end

	local detected = (fmt == "hsla" or parts[4] ~= nil) and "hsla" or "hsl"
	return M.from_hsl(h, s, l, a), detected
end

local function parse_hsv(args)
	local parts = split_args(args)
	if #parts < 3 then
		return nil
	end

	local h = parse_hue(parts[1])
	local s = parse_percent(parts[2])
	local v = parse_percent(parts[3])
	local a = parse_alpha(parts[4])
	if not (h and s and v and a) then
		return nil
	end

	return M.from_hsv(h, s, v, a), "hsv"
end

---Parse a color from common authoring formats.
---
---Supported inputs include `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`,
---`0xrrggbb`, `0xaarrggbb`, `rgb()`, `rgba()`, `hsl()`, `hsla()`,
---`hsv()` and common CSS color names.
---@param value string
---@return DotconfigColor? color
---@return string? format Detected format (`hex`, `rgb`, `hsl`, etc.).
---@return string? error Human readable parse error when parsing fails.
function M.parse(value)
	local text = trim(value):lower()
	if text == "" then
		return nil, nil, "empty color value"
	end

	if M.names[text] then
		local color, fmt = parse_hex(M.names[text])
		return color, text == "transparent" and "hexa" or fmt
	end

	local color, fmt = parse_hex(text)
	if color then
		return M.normalize(color), fmt
	end

	local name, args = text:match("^([%a]+)%s*%((.*)%)$")
	if name and args then
		if name == "rgb" or name == "rgba" then
			color, fmt = parse_rgb(args, name)
		elseif name == "hsl" or name == "hsla" then
			color, fmt = parse_hsl(args, name)
		elseif name == "hsv" or name == "hsb" then
			color, fmt = parse_hsv(args)
		end
		if color then
			return color, fmt
		end
	end

	return nil, nil, ("could not parse color value: %s"):format(value)
end

local function percent(value)
	return tostring(round(value)) .. "%"
end

local function alpha_string(value)
	return ("%.2f"):format(round(value, 2)):gsub("0+$", ""):gsub("%.$", "")
end

---Format a color for insertion/copying.
---@param c DotconfigColor
---@param fmt string
---@return string
function M.format(c, fmt)
	c = M.normalize(c)
	fmt = fmt or "hex"

	if fmt == "hex" then
		return M.to_hex(c, false)
	elseif fmt == "hexa" then
		return M.to_hex(c, true)
	elseif fmt == "rgb0x" then
		return "0x" .. component_to_hex(c.r) .. component_to_hex(c.g) .. component_to_hex(c.b)
	elseif fmt == "argb0x" then
		return "0x" .. alpha_to_hex(c.a) .. component_to_hex(c.r) .. component_to_hex(c.g) .. component_to_hex(c.b)
	elseif fmt == "rgb" then
		return ("rgb(%d, %d, %d)"):format(c.r, c.g, c.b)
	elseif fmt == "rgba" then
		return ("rgba(%d, %d, %d, %s)"):format(c.r, c.g, c.b, alpha_string(c.a))
	elseif fmt == "hsl" or fmt == "hsla" then
		local hsl = M.to_hsl(c)
		if fmt == "hsla" then
			return ("hsla(%d, %s, %s, %s)"):format(round(hsl.h), percent(hsl.s), percent(hsl.l), alpha_string(c.a))
		end
		return ("hsl(%d, %s, %s)"):format(round(hsl.h), percent(hsl.s), percent(hsl.l))
	elseif fmt == "hsv" then
		local hsv = M.to_hsv(c)
		return ("hsv(%d, %s, %s)"):format(round(hsv.h), percent(hsv.s), percent(hsv.v))
	end

	return M.to_hex(c, c.a < 1)
end

---Return every supported representation for a color.
---@param c DotconfigColor
---@return table<string, string>
function M.formatted(c)
	local ret = {}
	for _, fmt in ipairs(M.formats) do
		ret[fmt] = M.format(c, fmt)
	end
	return ret
end

---Find a channel definition by short key (`h`, `s`, `r`, etc.).
---@param key string
---@return table?
function M.channel_def(key)
	for _, def in ipairs(M.channel_defs) do
		if def.key == key then
			return def
		end
	end
end

---Read the current value for a color channel.
---@param c DotconfigColor
---@param key string
---@return number
function M.channel_value(c, key)
	c = M.normalize(c)
	if key == "r" or key == "g" or key == "b" then
		return c[key]
	end
	if key == "a" then
		return round(c.a * 100)
	end
	local hsl = M.to_hsl(c)
	return hsl[key] or 0
end

---Set one channel while preserving all other channels as much as possible.
---@param c DotconfigColor
---@param key string
---@param value number
---@return DotconfigColor
function M.set_channel(c, key, value)
	c = M.normalize(c)
	local def = M.channel_def(key)
	if not def then
		return c
	end

	if key == "r" or key == "g" or key == "b" then
		c[key] = clamp(round(value), def.min, def.max)
		return M.normalize(c)
	end

	if key == "a" then
		c.a = clamp(value, def.min, def.max) / 100
		return M.normalize(c)
	end

	local hsl = M.to_hsl(c)
	if key == "h" then
		hsl.h = ((value % 360) + 360) % 360
	elseif key == "s" or key == "l" then
		hsl[key] = clamp(value, def.min, def.max)
	end
	return M.from_hsl(hsl.h, hsl.s, hsl.l, c.a)
end

---Adjust a channel by a delta, wrapping hue and clamping all other channels.
---@param c DotconfigColor
---@param key string
---@param delta number
---@return DotconfigColor
function M.adjust_channel(c, key, delta)
	local def = M.channel_def(key)
	if not def then
		return M.normalize(c)
	end
	return M.set_channel(c, key, M.channel_value(c, key) + delta)
end

---Pick a readable text color for a background swatch.
---@param c DotconfigColor|string
---@return string hex `#000000` or `#ffffff`.
function M.contrast(c)
	if type(c) == "string" then
		c = M.parse(c) or { r = 0, g = 0, b = 0, a = 1 }
	end
	c = M.normalize(c)
	local function linear(channel)
		channel = channel / 255
		return channel <= 0.03928 and channel / 12.92 or ((channel + 0.055) / 1.055) ^ 2.4
	end
	local luminance = 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
	return luminance > 0.5 and "#000000" or "#ffffff"
end

local function add_match(matches, line, start_idx, end_idx)
	local text = line:sub(start_idx, end_idx)
	local color, fmt = M.parse(text)
	if color then
		matches[#matches + 1] = {
			start_col = start_idx - 1,
			end_col = end_idx,
			text = text,
			color = color,
			format = fmt,
		}
	end
end

local function overlaps(a, b)
	return a.start_col < b.end_col and b.start_col < a.end_col
end

---Find parseable color literals in a single line of text.
---
---The returned columns are byte-based and compatible with `nvim_buf_set_text`.
---@param line string
---@return table[] matches
function M.find_all(line)
	local matches = {}
	local start = 1
	while true do
		local s, e = line:find("#%x+", start)
		if not s then
			break
		end
		add_match(matches, line, s, e)
		start = e + 1
	end

	start = 1
	while true do
		local s, e = line:find("%f[%w_]0[xX]%x+%f[^%w_]", start)
		if not s then
			break
		end
		add_match(matches, line, s, e)
		start = e + 1
	end

	start = 1
	while true do
		local s, e = line:find("[%a]+%s*%b()", start)
		if not s then
			break
		end
		add_match(matches, line, s, e)
		start = e + 1
	end

	start = 1
	while true do
		local s, e = line:find("%f[%a][%a]+%f[^%a]", start)
		if not s then
			break
		end
		local name = line:sub(s, e):lower()
		if M.names[name] then
			local candidate = { start_col = s - 1, end_col = e }
			local covered = false
			for _, existing in ipairs(matches) do
				if overlaps(candidate, existing) then
					covered = true
					break
				end
			end
			if not covered then
				add_match(matches, line, s, e)
			end
		end
		start = e + 1
	end

	table.sort(matches, function(a, b)
		return a.start_col < b.start_col
	end)
	return matches
end

---Find the color under or immediately before the cursor column.
---@param line string
---@param col number 0-based byte column.
---@return table? match
function M.find_at(line, col)
	for _, match in ipairs(M.find_all(line)) do
		if match.start_col <= col and col <= match.end_col then
			return match
		end
	end
	return nil
end

return M
