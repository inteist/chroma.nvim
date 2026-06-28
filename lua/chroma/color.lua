---@class DotconfigColor
---@field r number Red channel in the 0-255 range.
---@field g number Green channel in the 0-255 range.
---@field b number Blue channel in the 0-255 range.
---@field a number Alpha channel in the 0-1 range.

local M = {}

M.formats = {
	"hex",
	"hexa",
	"rgb0x",
	"argb0x",
	"rgb",
	"rgba",
	"argb",
	"hsl",
	"hsla",
	"hsv",
}

M.format_labels = {
	hex = "HEX",
	hexa = "HEX + Alpha",
	rgb0x = "0x RGB",
	argb0x = "0x ARGB",
	rgb = "RGB",
	rgba = "RGBA",
	argb = "ARGB",
	hsl = "HSL",
	hsla = "HSLA",
	hsv = "HSV",
}

local named_paren_formats = {
	rgb = true,
	rgba = true,
	argb = true,
	hsl = true,
	hsla = true,
	hsv = true,
	hsb = true,
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
		-- 0x-prefixed 8-digit colors are parsed as Android-style AARRGGBB.
		-- Keep alpha as a normalized float so alpha_to_hex() can round-trip it.
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

-- Stricter variant of `parse_number` that rejects any leading/trailing
-- non-numeric characters and explicitly signals whether the value was a
-- percentage. Returns three values: the parsed number, a boolean
-- `is_percent`, and the raw (trimmed, stripped of %) string so callers can
-- inspect it directly (e.g. to detect a decimal point).
local function parse_strict_number(value)
	local text = trim(value):lower()
	local is_percent = false
	if text:sub(-1) == "%" then
		is_percent = true
		text = trim(text:sub(1, -2))
	end
	if not text:match("^[-+]?%d*%.?%d+$") then
		return nil
	end
	---@return number?, boolean, string
	return tonumber(text), is_percent, text
end

local function parse_tuple_rgb_component(value)
	local number, is_percent = parse_strict_number(value)
	if not number then
		return nil
	end
	if is_percent then
		number = number * 255 / 100
	end
	return clamp(round(number), 0, 255)
end

-- Try to interpret `value` as a tuple alpha component and return (alpha,
-- kind) or nil.
--
-- "kind" is one of:
--   "explicit" – the value is unambiguously alpha-domain (a decimal fraction
--                or a percentage), and can be used even for unit-range tuples.
--   "unit"     – the value is literally `0` or `1`. It looks alpha-like but
--                is also a plausible small coordinate/flag, so the caller must
--                verify that the remaining channels look colour-like before
--                committing to an ARGB/RGBA interpretation.
local function parse_tuple_alpha(value)
	local number, is_percent, raw = parse_strict_number(value)
	if not number then
		return nil
	end
	if is_percent then
		if number < 0 or number > 100 then
			return nil
		end
		return clamp(number / 100, 0, 1), "explicit"
	end
	-- Only values in [0, 1] can be a unit-range alpha at all.
	if number < 0 or number > 1 then
		return nil
	end
	-- A decimal point makes the alpha intent unambiguous (e.g. `0.8`).
	if raw:find("%.") then
		return clamp(number, 0, 1), "explicit"
	end
	-- The bare integers `0` and `1` are alpha-like but cannot be
	-- distinguished from small coordinates on their own.
	if raw == "0" or raw == "1" then
		return clamp(number, 0, 1), "unit"
	end
	return nil
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

-- Parse `argb(alpha, r, g, b)`. Uses the same lenient alpha rules as
-- `rgba()`: a bare value greater than 1 is treated as a percentage,
-- matching common design-tool output (e.g. `argb(80, 255, 255, 255)`).
local function parse_argb(args)
	local parts = split_args(args)
	if #parts < 4 then
		return nil
	end

	local a = parse_alpha(parts[1])
	local r = parse_rgb_component(parts[2])
	local g = parse_rgb_component(parts[3])
	local b = parse_rgb_component(parts[4])
	if not (a and r and g and b) then
		return nil
	end

	return M.normalize({ r = r, g = g, b = b, a = a }), "argb"
end

-- Return true when the RGB-position channels in `parts` at `indexes` look
-- like colour components rather than generic coordinates or flags.
--
-- Heuristics (any one is sufficient):
--   • A percentage suffix (`50%`)    → unambiguously a colour channel.
--   • A decimal point (`10.5`)       → fractional, not a plain integer.
--   • Value >= 16                    → above the highest plausible alpha
--     percentage that is also a small integer, so almost certainly an RGB
--     byte (valid range 0-255). The threshold 16 is chosen conservatively:
--     it is impossible to have alpha = 16 that looks like a colour-channel
--     value in a 4-element tuple where another field is 0 or 1.
--   • A repeated value               → e.g. `(1, 1, 1, 0)` — the duplicate
--     makes it very unlikely to be a plain coordinate list.
local function tuple_rgb_looks_color_like(parts, indexes)
	local seen = {}
	for _, idx in ipairs(indexes) do
		local number, is_percent, raw = parse_strict_number(parts[idx])
		if not number then
			return false
		end
		if is_percent or raw:find("%.") or number >= 16 then
			return true
		end
		local key = tostring(number)
		if seen[key] then
			return true
		end
		seen[key] = true
	end
	return false
end

-- When the candidate alpha kind is "unit" (bare `0` or `1`), require the
-- remaining channels to pass the colour-likeness check before accepting the
-- tuple as a colour. "explicit" alphas (fractions / percentages) are always
-- trusted without extra validation.
local function tuple_alpha_is_usable(kind, parts, indexes)
	return kind ~= "unit" or tuple_rgb_looks_color_like(parts, indexes)
end

-- Shared implementation: parse three raw string values as RGB components,
-- combine with the already-parsed alpha, normalise, and return under the
-- regular function-call format family (`rgba` / `argb`).
local function build_color_tuple(r_raw, g_raw, b_raw, a, fmt)
	local r = parse_tuple_rgb_component(r_raw)
	local g = parse_tuple_rgb_component(g_raw)
	local b = parse_tuple_rgb_component(b_raw)
	if not (r and g and b and a) then
		return nil
	end
	return M.normalize({ r = r, g = g, b = b, a = a }), fmt
end

-- Attempt to parse a bare parenthesised 4-element numeric tuple as either
-- an RGBA tuple `(r, g, b, a)` or an ARGB tuple `(a, r, g, b)`.
--
-- Disambiguation strategy:
--   1. Check whether the first and last elements look like alpha values.
--   2. Prefer the last element as alpha (RGBA layout) when:
--        • only the last element is alpha-like, OR
--        • both ends look alpha-like but the last is "explicit" and the
--          first is only "unit" (bare 0/1).
--   3. Prefer the first element as alpha (ARGB layout) under the symmetric
--      condition.
--   4. When the winning alpha kind is "unit", additionally verify that the
--      RGB channels look colour-like — this filters out plain coordinate
--      tuples such as `(1, 2, 3, 4)` that would otherwise be misdetected.
local function parse_tuple(args)
	local parts = split_args(args)
	if #parts ~= 4 then
		return nil
	end

	local first_alpha, first_alpha_kind = parse_tuple_alpha(parts[1])
	local last_alpha, last_alpha_kind = parse_tuple_alpha(parts[4])

	-- RGBA layout: last element is the alpha.
	local last_wins = last_alpha
		and (not first_alpha or (last_alpha_kind == "explicit" and first_alpha_kind == "unit"))
	-- ARGB layout: first element is the alpha.
	local first_wins = first_alpha
		and (not last_alpha or (first_alpha_kind == "explicit" and last_alpha_kind == "unit"))

	if last_wins then
		if tuple_alpha_is_usable(last_alpha_kind, parts, { 1, 2, 3 }) then
			return build_color_tuple(parts[1], parts[2], parts[3], last_alpha, "rgba")
		end
	elseif first_wins then
		if tuple_alpha_is_usable(first_alpha_kind, parts, { 2, 3, 4 }) then
			return build_color_tuple(parts[2], parts[3], parts[4], first_alpha, "argb")
		end
	end
	return nil
end

-- Generic language wrappers like `Color(...)` may carry RGB triplets without
-- the literal `rgb` prefix. Keep this scoped to prefixed calls (not bare
-- tuples) and require colour-like channels to avoid treating common coordinate
-- triples as colours.
local function parse_prefixed_tuple(args)
	local parsed, fmt = parse_tuple(args)
	if parsed then
		return parsed, fmt
	end

	local parts = split_args(args)
	if #parts ~= 3 or not tuple_rgb_looks_color_like(parts, { 1, 2, 3 }) then
		return nil
	end
	local r = parse_tuple_rgb_component(parts[1])
	local g = parse_tuple_rgb_component(parts[2])
	local b = parse_tuple_rgb_component(parts[3])
	if not (r and g and b) then
		return nil
	end
	return M.normalize({ r = r, g = g, b = b, a = 1 }), "rgb"
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

---Return the inner argument span for an arbitrary prefixed parenthesised
---RGB/RGBA/ARGB tuple. Built-in colour functions (`rgba(...)`,
---`argb(...)`, etc.) own their prefix as part of the format, but
---language-specific wrappers like
---`Color(...)` or `make_color(...)` should keep the wrapper and replace only
---the numeric colour arguments.
---@param value string
---@param fmt? string
---@return table? span 0-based `{ start_col, end_col }` relative to `value`.
function M.replacement_span(value, fmt)
	if fmt and fmt ~= "rgb" and fmt ~= "rgba" and fmt ~= "argb" then
		return nil
	end

	local text = trim(value)
	local name = text:match("^([%a_][%w_%.:]*)%s*%b()$")
	if not (name and name:match("[%w_]$")) then
		return nil
	end
	if named_paren_formats[name:lower()] then
		return nil
	end

	local paren_start = text:find("%(")
	if not paren_start then
		return nil
	end
	return {
		start_col = paren_start,
		end_col = #text - 1,
		mode = "args",
		suffix_len = 1,
	}
end

---Parse a color from common authoring formats.
---
---Supported inputs include `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`,
---`0xrrggbb`, `0xaarrggbb`, `rgb()`, `rgba()`, `argb()`, and
---prefixed RGB tuples like `Color(255, 255, 255)`, and parenthesised
---RGBA/ARGB numeric tuples like `(255, 255, 255, 0.8)` /
---`(0.3, 255, 255, 255)` with or without an arbitrary identifier prefix,
---plus `hsl()`, `hsla()`, `hsv()` and common CSS color names.
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

	local tuple_args = text:match("^%((.*)%)$")
	if tuple_args then
		color, fmt = parse_tuple(tuple_args)
		if color then
			return color, fmt
		end
	end

	local name, args = text:match("^([%a_][%w_%.:]*)%s*%((.*)%)$")
	if name and args and name:match("[%w_]$") then
		if name == "rgb" or name == "rgba" then
			color, fmt = parse_rgb(args, name)
		elseif name == "argb" then
			color, fmt = parse_argb(args)
		elseif name == "hsl" or name == "hsla" then
			color, fmt = parse_hsl(args, name)
		elseif name == "hsv" or name == "hsb" then
			color, fmt = parse_hsv(args)
		else
			color, fmt = parse_prefixed_tuple(args)
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

---Format just the comma-separated argument list for parenthesised formats.
---@param c DotconfigColor
---@param fmt string
---@return string
function M.format_args(c, fmt)
	c = M.normalize(c)
	fmt = fmt or "rgba"

	if fmt == "rgb" then
		return ("%d, %d, %d"):format(c.r, c.g, c.b)
	elseif fmt == "argb" then
		return ("%s, %d, %d, %d"):format(alpha_string(c.a), c.r, c.g, c.b)
	elseif fmt == "hsl" or fmt == "hsla" then
		local hsl = M.to_hsl(c)
		if fmt == "hsla" then
			return ("%d, %s, %s, %s"):format(round(hsl.h), percent(hsl.s), percent(hsl.l), alpha_string(c.a))
		end
		return ("%d, %s, %s"):format(round(hsl.h), percent(hsl.s), percent(hsl.l))
	elseif fmt == "hsv" then
		local hsv = M.to_hsv(c)
		return ("%d, %s, %s"):format(round(hsv.h), percent(hsv.s), percent(hsv.v))
	end

	if fmt == "rgba" then
		return ("%d, %d, %d, %s"):format(c.r, c.g, c.b, alpha_string(c.a))
	end
	return M.format(c, fmt)
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
	elseif fmt == "argb" then
		return ("argb(%s, %d, %d, %d)"):format(alpha_string(c.a), c.r, c.g, c.b)
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

-- Forward declaration: `add_match` (defined next) calls `overlaps`, and
-- `overlaps` is defined immediately after. The upvalue is shared between
-- both closures so they can reference each other without a module-level table.
local overlaps

local function add_match(matches, line, start_idx, end_idx)
	local candidate = { start_col = start_idx - 1, end_col = end_idx }
	for _, existing in ipairs(matches) do
		if overlaps(candidate, existing) then
			return
		end
	end

	local text = line:sub(start_idx, end_idx)
	local color, fmt = M.parse(text)
	if color then
		local match = {
			start_col = candidate.start_col,
			end_col = candidate.end_col,
			text = text,
			color = color,
			format = fmt,
		}
		local span = M.replacement_span(text, fmt)
		if span then
			match.replace_start_col = candidate.start_col + span.start_col
			match.replace_end_col = candidate.start_col + span.end_col
			match.replace_mode = span.mode
			match.replace_text = line:sub(match.replace_start_col + 1, match.replace_end_col)
			match.replace_suffix_len = span.suffix_len or 0
		end
		matches[#matches + 1] = match
	end
end

function overlaps(a, b)
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
		local s, e = line:find("%f[%a_][%a_][%w_%.:]*%s*%b()", start)
		if not s then
			break
		end
		add_match(matches, line, s, e)
		start = e + 1
	end

	-- Scan for bare parenthesised tuples `(...)`. Function-style values with
	-- known or arbitrary identifier prefixes are captured by the pass above, so
	-- overlap checks prevent this pass from returning only their inner args. We
	-- walk one `(` at a time; `%b()` ensures we only match balanced pairs. For
	-- typical source lines this is O(n); pathological lines with many unmatched
	-- `(` characters could be quadratic, but that is not a realistic concern
	-- for colour literal scanning.
	start = 1
	while true do
		local s = line:find("%(", start)
		if not s then
			break
		end
		local balanced_start, e = line:find("%b()", s)
		if balanced_start == s and e then
			add_match(matches, line, s, e)
		end
		start = s + 1
	end

	start = 1
	while true do
		local s, e = line:find("%f[%a][%a]+%f[^%a]", start)
		if not s then
			break
		end
		local name = line:sub(s, e):lower()
		if M.names[name] then
			add_match(matches, line, s, e)
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
