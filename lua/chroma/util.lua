---Shared utility helpers for the color picker modules.
---
---Centralises the notification helper, Snacks accessor and small formatting
---functions that were previously duplicated across `ui.lua` and `store.lua`.
local M = {}

---Safely require the Snacks library, returning `nil` when unavailable.
---@return table?
function M.get_snacks()
	if _G.Snacks then
		return _G.Snacks
	end
	local ok, snacks = pcall(require, "snacks")
	if ok then
		return snacks
	end
	return nil
end

---Display a notification through Snacks when available, falling back to
---`vim.notify`.
---@param message string
---@param level? string
function M.notify(message, level)
	local snacks = M.get_snacks()
	if snacks and snacks.notify then
		snacks.notify(message, { level = level or "info", title = "Color Picker" })
	else
		vim.notify(
			message,
			vim.log.levels[(level or "info"):upper()] or vim.log.levels.INFO,
			{ title = "Color Picker" }
		)
	end
end

---Copy a value to both the system clipboard (`+`) and the unnamed register.
---@param value string
function M.copy_to_clipboard(value)
	vim.fn.setreg("+", value)
	vim.fn.setreg('"', value)
end

---Right-pad a string with spaces to reach the target display width.
---@param value any
---@param width number
---@return string
function M.align(value, width)
	value = tostring(value or "")
	local pad = width - vim.api.nvim_strwidth(value)
	if pad <= 0 then
		return value
	end
	return value .. string.rep(" ", pad)
end

---Convert a decimal color integer to a `#rrggbb` hex string.
---@param value number?
---@param fallback string
---@return string
function M.dec_to_hex(value, fallback)
	if not value then
		return fallback
	end
	return string.format("#%06x", value)
end

---Resolve a highlight group property, trying Snacks' color helper first
---and falling back to the Neovim highlight API.
---@param group string
---@param prop? string `"fg"` or `"bg"`.
---@param fallback string
---@return string
function M.theme_color(group, prop, fallback)
	local snacks = M.get_snacks()
	if snacks and snacks.util and snacks.util.color then
		local ok, value = pcall(snacks.util.color, group, prop)
		if ok and value then
			return value
		end
	end
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
	if ok and hl then
		return M.dec_to_hex(hl[prop or "fg"], fallback)
	end
	return fallback
end

---Pcall-wrapped `nvim_set_hl` — silently ignores errors.
---@param name string
---@param spec table
function M.set_hl(name, spec)
	pcall(vim.api.nvim_set_hl, 0, name, spec)
end

return M
