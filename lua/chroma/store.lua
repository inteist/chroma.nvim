local color = require("chroma.color")
local util = require("chroma.util")

local notify = util.notify

local M = {}

local config = {
	path = vim.fn.stdpath("state") .. "/chroma.nvim/palettes.json",
	max_recents = 32,
}

local cache ---@type table?

local default_data = {
	version = 1,
	recents = {},
	palettes = {
		{
			name = "Dotconfig Vivid",
			colors = {
				{ hex = "#161616", label = "Editor background" },
				{ hex = "#e5e5e5", label = "Foreground" },
				{ hex = "#4fa5e8", label = "Keyword blue" },
				{ hex = "#7cd5ff", label = "Variable blue" },
				{ hex = "#e572d3", label = "Magenta" },
				{ hex = "#ffd866", label = "Function yellow" },
				{ hex = "#35e6b7", label = "Type teal" },
				{ hex = "#ec8f6e", label = "String salmon" },
				{ hex = "#72b068", label = "Comment green" },
				{ hex = "#f44747", label = "Error red" },
			},
		},
	},
}

local function now() return os.time() end

local function deepcopy(value) return vim.deepcopy(value) end

local function read_json(path)
	if vim.uv.fs_stat(path) == nil then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil
	end

	local ok_decode, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if ok_decode and type(decoded) == "table" then
		return decoded
	end
	return nil
end

local function write_json(path, data)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local ok, encoded = pcall(vim.json.encode, data)
	if not ok then
		notify("Failed to encode color palettes", "error")
		return false
	end
	local ok_write, err = pcall(vim.fn.writefile, { encoded }, path)
	if not ok_write then
		notify("Failed to save color palettes: " .. tostring(err), "error")
		return false
	end
	return true
end

local function color_key(entry)
	local parsed = color.parse(entry.hex or entry.value or entry[1] or "")
	return parsed and color.to_hex(parsed, true) or tostring(entry.hex or entry.value or entry[1] or ""):lower()
end

local function normalize_entry(entry)
	if type(entry) == "string" then
		entry = { hex = entry }
	end
	if type(entry) ~= "table" then
		return nil
	end

	local parsed = color.parse(entry.hex or entry.value or entry[1] or "")
	if not parsed then
		return nil
	end

	return {
		hex = color.to_hex(parsed, parsed.a < 1),
		label = entry.label or entry.name,
		created_at = entry.created_at or now(),
		used_at = entry.used_at or entry.updated_at or now(),
	}
end

local function normalize_palette(palette)
	if type(palette) ~= "table" then
		return nil
	end

	local normalized = {
		name = palette.name or "Custom",
		colors = {},
	}

	for _, entry in ipairs(palette.colors or palette) do
		local item = normalize_entry(entry)
		if item then
			normalized.colors[#normalized.colors + 1] = item
		end
	end

	return normalized
end

local function normalize_data(data)
	data = type(data) == "table" and data or deepcopy(default_data)
	local normalized = {
		version = 1,
		recents = {},
		palettes = {},
	}

	for _, entry in ipairs(data.recents or {}) do
		local item = normalize_entry(entry)
		if item then
			normalized.recents[#normalized.recents + 1] = item
		end
	end

	for _, palette in ipairs(data.palettes or {}) do
		local item = normalize_palette(palette)
		if item and #item.colors > 0 then
			normalized.palettes[#normalized.palettes + 1] = item
		end
	end

	if #normalized.palettes == 0 then
		normalized.palettes = deepcopy(default_data.palettes)
	end

	return normalized
end

local function find_palette(data, name)
	for _, palette in ipairs(data.palettes) do
		if palette.name == name then
			return palette
		end
	end
	local palette = { name = name, colors = {} }
	data.palettes[#data.palettes + 1] = palette
	return palette
end

local function remove_duplicate(list, key)
	for i = #list, 1, -1 do
		if color_key(list[i]) == key then
			table.remove(list, i)
		end
	end
end

---Configure the palette store.
---@param opts? { path?: string, max_recents?: number }
function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
	cache = nil
end

---Return the palette JSON path used by the store.
---@return string
function M.path() return config.path end

---Load palette data from disk, creating an in-memory default model when needed.
---@return table
function M.load()
	if cache then
		return cache
	end
	cache = normalize_data(read_json(config.path) or default_data)
	return cache
end

---Persist the current palette model to disk.
---@return boolean
function M.save() return write_json(config.path, M.load()) end

---Remember a color at the top of the recent list.
---@param value string|DotconfigColor
---@param label? string
---@return table? entry
function M.add_recent(value, label)
	local parsed = type(value) == "table" and color.normalize(value) or color.parse(value)
	if not parsed then
		return nil
	end

	local entry = {
		hex = color.to_hex(parsed, parsed.a < 1),
		label = label,
		created_at = now(),
		used_at = now(),
	}
	local data = M.load()
	remove_duplicate(data.recents, color_key(entry))
	table.insert(data.recents, 1, entry)
	while #data.recents > config.max_recents do
		table.remove(data.recents)
	end
	M.save()
	return entry
end

---Return the most recently used color entry, if one has been recorded.
---
---The UI uses this to seed new picker sessions with the user's last working
---color instead of falling back to a hard-coded default every time.
---@return table? entry
function M.last_recent()
	local entry = M.load().recents[1]
	return entry and deepcopy(entry) or nil
end

---Save or update a color in a named custom palette.
---@param palette_name string
---@param value string|DotconfigColor
---@param label? string
---@return table? entry
function M.add_to_palette(palette_name, value, label)
	palette_name = vim.trim(palette_name or "")
	if palette_name == "" then
		palette_name = "Custom"
	end

	local parsed = type(value) == "table" and color.normalize(value) or color.parse(value)
	if not parsed then
		return nil
	end

	local data = M.load()
	local palette = find_palette(data, palette_name)
	local entry = {
		hex = color.to_hex(parsed, parsed.a < 1),
		label = label,
		created_at = now(),
		used_at = now(),
	}
	remove_duplicate(palette.colors, color_key(entry))
	table.insert(palette.colors, 1, entry)
	M.save()
	return entry
end

---Remove an item returned from `items()`.
---@param item table
---@return boolean
function M.remove(item)
	local data = M.load()
	if item.scope == "recent" then
		for i = #data.recents, 1, -1 do
			if i == item.index or color_key(data.recents[i]) == item.key then
				table.remove(data.recents, i)
				M.save()
				return true
			end
		end
	elseif item.scope == "palette" then
		for _, palette in ipairs(data.palettes) do
			if palette.name == item.palette then
				for i = #palette.colors, 1, -1 do
					if i == item.index or color_key(palette.colors[i]) == item.key then
						table.remove(palette.colors, i)
						M.save()
						return true
					end
				end
			end
		end
	end
	return false
end

---Rename a palette/recent item returned from `items()`.
---
---An empty label intentionally clears the name, which makes quick cleanup from
---the palette picker possible without editing the JSON file by hand.
---@param item table Picker item returned by `items()`.
---@param label string? New display label. Empty string clears the label.
---@return boolean
function M.rename(item, label)
	local data = M.load()
	local clean_label = vim.trim(label or "")
	local next_label = clean_label ~= "" and clean_label or nil

	if item.scope == "recent" then
		for i, entry in ipairs(data.recents) do
			if i == item.index or color_key(entry) == item.key then
				entry.label = next_label
				entry.used_at = now()
				M.save()
				return true
			end
		end
	elseif item.scope == "palette" then
		for _, palette in ipairs(data.palettes) do
			if palette.name == item.palette then
				for i, entry in ipairs(palette.colors) do
					if i == item.index or color_key(entry) == item.key then
						entry.label = next_label
						entry.used_at = now()
						M.save()
						return true
					end
				end
			end
		end
	end

	return false
end

---Return a flat, picker-friendly list of recent and palette colors.
---@return table[]
function M.items()
	local data = M.load()
	local ret = {}

	for index, entry in ipairs(data.recents) do
		ret[#ret + 1] = vim.tbl_extend("force", deepcopy(entry), {
			scope = "recent",
			palette = "Recent",
			index = index,
			key = color_key(entry),
		})
	end

	for _, palette in ipairs(data.palettes) do
		for index, entry in ipairs(palette.colors) do
			ret[#ret + 1] = vim.tbl_extend("force", deepcopy(entry), {
				scope = "palette",
				palette = palette.name,
				index = index,
				key = color_key(entry),
			})
		end
	end

	return ret
end

---Return available palette names for prompts and picker labels.
---@return string[]
function M.palette_names()
	local names = {}
	for _, palette in ipairs(M.load().palettes) do
		names[#names + 1] = palette.name
	end
	return names
end

return M
