---Shared utility helpers for the color picker modules.
---
---The helpers in this module are intentionally small wrappers around Neovim's
---built-in APIs.  Keeping notifications, highlight lookups, throttling and
---formatting utilities here prevents UI modules from depending on external
---libraries or duplicating compatibility logic.

local M = {}

local unpack = unpack or table.unpack

---Display a Chroma-scoped notification through Neovim's native notifier.
---@param message string
---@param level? string One of `"info"`, `"warn"`, or `"error"`.
function M.notify(message, level)
	local level_name = (level or "info"):upper()
	vim.notify(message, vim.log.levels[level_name] or vim.log.levels.INFO, { title = "Color Picker" })
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

---Resolve a highlight group property through the Neovim highlight API.
---@param group string
---@param prop? string `"fg"` or `"bg"`.
---@param fallback string
---@return string
function M.theme_color(group, prop, fallback)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
	if not (ok and hl) then
		return fallback
	end
	local value = hl[prop or "fg"]
	if type(value) == "number" then
		return M.dec_to_hex(value, fallback)
	end
	if type(value) == "string" and value ~= "" then
		return value
	end
	return fallback
end

---Pcall-wrapped `nvim_set_hl` — silently ignores errors.
---@param name string
---@param spec table
function M.set_hl(name, spec)
	pcall(vim.api.nvim_set_hl, 0, name, spec)
end

---Create a leading-edge throttle wrapper.
---
---The returned function invokes `fn` immediately when enough time has elapsed
---since the last call.  Calls made during the cooldown are coalesced and the
---latest arguments are replayed once at the end of the interval.  This keeps
---live editor previews responsive while avoiding excessive buffer writes when
---a key is held down.
---@param fn fun(...)
---@param ms number Minimum interval between calls in milliseconds.
---@return fun(...)
function M.throttle(fn, ms)
	ms = tonumber(ms) or 0
	local uv = vim.uv or vim.loop
	if ms <= 0 or not (uv and uv.new_timer) then
		return fn
	end

	local timer ---@type uv.uv_timer_t?
	local queued_args ---@type table?
	local last_call = 0

	local function invoke(args)
		last_call = uv.hrtime() / 1e6
		fn(unpack(args, 1, args.n))
	end

	local function close_timer(handle)
		if handle then
			pcall(handle.stop, handle)
			pcall(handle.close, handle)
		end
	end

	local function start_timer(delay)
		timer = uv.new_timer()
		timer:start(delay, 0, function()
			local args = queued_args
			queued_args = nil
			local handle = timer
			timer = nil
			close_timer(handle)
			if args then
				vim.schedule(function()
					invoke(args)
				end)
			end
		end)
	end

	return function(...)
		queued_args = { n = select("#", ...), ... }
		local elapsed = (uv.hrtime() / 1e6) - last_call
		local delay = ms - elapsed
		if delay <= 0 and not timer then
			local args = queued_args
			queued_args = nil
			invoke(args)
		elseif not timer then
			start_timer(math.max(1, math.floor(delay)))
		end
	end
end

return M
