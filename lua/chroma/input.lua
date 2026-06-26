---Input helpers for Chroma prompts.
---
---This module wraps Neovim's built-in `vim.ui.input` so the rest of the plugin
---does not depend on any external UI framework.  Centralising prompt handling
---also keeps future enhancements (validation, custom completion, themed prompt
---providers) isolated from the picker state machine.

local M = {}

---Prompt the user for a string value.
---
---`on_confirm` receives `nil` when the prompt is cancelled, matching
---`vim.ui.input` semantics.  The fallback to `vim.fn.input()` is only here for
---defensive compatibility; Chroma's supported Neovim versions provide
---`vim.ui.input`.
---@param opts { prompt?: string, default?: string, completion?: string|fun(...): any }
---@param on_confirm fun(value?: string)
function M.prompt(opts, on_confirm)
	opts = opts or {}
	if vim.ui and vim.ui.input then
		vim.ui.input({
			prompt = opts.prompt,
			default = opts.default,
			completion = opts.completion,
		}, on_confirm)
		return
	end

	local ok, value = pcall(vim.fn.input, {
		prompt = opts.prompt or "",
		default = opts.default or "",
		completion = opts.completion,
	})
	on_confirm(ok and value or nil)
end

return M
