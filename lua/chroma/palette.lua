---Palette / recent-colors manager window for the color picker.
---
---Provides the floating buffer where users browse saved/recent colors,
---edit labels inline, and select a color to feed back into the main picker.

local color = require("chroma.color")
local store = require("chroma.store")
local geo = require("chroma.geometry")
local hl_mod = require("chroma.highlights")
local util = require("chroma.util")
local window = require("chroma.window")

local align = util.align
local notify = util.notify
local copy_to_clipboard = util.copy_to_clipboard

local palette_ns = vim.api.nvim_create_namespace("chroma_palette")

---Per-buffer metadata for open palette windows.
---@type table<number, table>
local palette_buffers = {}

local M = {}

-- ── Data helpers ─────────────────────────────────────────────────────────────

---Build a flat, searchable list of palette/recent items.
---@param recents_only? boolean
---@return table[]
local function palette_items(recents_only)
	local items = {}
	for _, item in ipairs(store.items()) do
		if not recents_only or item.scope == "recent" then
			local parsed = color.parse(item.hex)
			if parsed then
				item.text = table.concat({
					item.palette,
					item.hex,
					item.label or "",
					color.format(parsed, "rgb"),
					color.format(parsed, "hsl"),
				}, " ")
				items[#items + 1] = item
			end
		end
	end
	return items
end

---Render a single palette line with column-aligned segments.
---@param item table
---@return table
local function palette_line(item)
	local parsed = color.parse(item.hex)
	local hex = parsed and color.to_hex(parsed, parsed.a < 1) or item.hex
	local swatch = "██"
	local before_palette = "  " .. swatch .. "  "
	local palette_text = align(item.palette, 18)
	local before_hex = before_palette .. palette_text .. "  "
	local hex_text = align(hex, 10)
	local prefix = before_hex .. hex_text .. "  "

	return {
		line = prefix .. (item.label or ""),
		prefix = prefix,
		hex = hex,
		swatch_start = #"  ",
		swatch_end = #"  " + #swatch,
		palette_start = #before_palette,
		palette_end = #before_palette + #palette_text,
		hex_start = #before_hex,
		hex_end = #before_hex + #hex_text,
	}
end

-- ── Footer ───────────────────────────────────────────────────────────────────

local function palette_footer()
	return {
		{ " ", "ChromaFooter" },
		{ " enter ", "ChromaFooterKey" },
		{ " use ", "ChromaFooterDesc" },
		{ " y ", "ChromaFooterKey" },
		{ " copy ", "ChromaFooterDesc" },
		{ " D ", "ChromaFooterKey" },
		{ " delete ", "ChromaFooterDesc" },
		{ " :w ", "ChromaFooterKey" },
		{ " save labels ", "ChromaFooterDesc" },
		{ " q ", "ChromaFooterKey" },
		{ " close ", "ChromaFooterDesc" },
		{ " ", "ChromaFooter" },
	}
end

-- ── Buffer rendering ─────────────────────────────────────────────────────────

---Render the palette items into the buffer.
---@param win ChromaWindow
---@param opts table
---@param cursor_lnum? number
---@return boolean
local function palette_render(win, opts, cursor_lnum)
	local buf = win.buf
	local items = palette_items(opts.recents_only)
	if #items == 0 then
		palette_buffers[buf] = nil
		notify("No saved colors yet", "warn")
		win:close()
		return false
	end

	local title = opts.recents_only and "Recent Colors" or "Color Palettes"
	local header = "      " .. align("Palette", 18) .. "  " .. align("Hex", 10) .. "  Label"
	local lines = { header, "" }
	local hls = {
		{ row = 0, start_col = 6, end_col = #header, hl = "ChromaTitle" },
	}
	local pending = {}

	for _, item in ipairs(items) do
		local rendered = palette_line(item)
		local row = #lines
		lines[#lines + 1] = rendered.line
		hls[#hls + 1] = {
			row = row,
			start_col = rendered.swatch_start,
			end_col = rendered.swatch_end,
			hl = hl_mod.swatch_hl(rendered.hex),
		}
		hls[#hls + 1] = {
			row = row,
			start_col = rendered.palette_start,
			end_col = rendered.palette_end,
			hl = item.scope == "recent" and "ChromaAccent" or "ChromaTitle",
		}
		hls[#hls + 1] = { row = row, start_col = rendered.hex_start, end_col = rendered.hex_end, hl = "ChromaValue" }
		if item.label and item.label ~= "" then
			hls[#hls + 1] = { row = row, start_col = #rendered.prefix, end_col = #rendered.line, hl = "ChromaMuted" }
		end
		pending[#pending + 1] = {
			row = row,
			item = item,
			hex = rendered.hex,
			label_start = #rendered.prefix,
		}
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(buf, palette_ns, 0, -1)
	for _, h in ipairs(hls) do
		vim.api.nvim_buf_add_highlight(buf, palette_ns, h.hl, h.row, h.start_col, h.end_col)
	end

	local model = {
		title = title,
		opts = opts,
		rows = {},
		first_lnum = 3,
		first_label_start = pending[1] and pending[1].label_start or 0,
	}
	for _, meta in ipairs(pending) do
		local mark = vim.api.nvim_buf_set_extmark(buf, palette_ns, meta.row, 0, { right_gravity = false })
		model.rows[mark] = {
			item = meta.item,
			hex = meta.hex,
			label_start = meta.label_start,
		}
	end
	palette_buffers[buf] = model
	vim.bo[buf].modified = false

	if win.win and vim.api.nvim_win_is_valid(win.win) then
		local lnum = math.min(math.max(cursor_lnum or model.first_lnum, model.first_lnum), #lines)
		vim.api.nvim_win_set_cursor(win.win, { lnum, model.first_label_start })
	end
	return true
end

-- ── Buffer save ──────────────────────────────────────────────────────────────

---Persist label edits from the palette buffer back to the store.
---@param buf number
---@param quiet? boolean
---@return boolean
local function palette_save_buffer(buf, quiet)
	local model = palette_buffers[buf]
	if not (model and vim.api.nvim_buf_is_valid(buf)) then
		return false
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local changed = 0
	for mark, meta in pairs(model.rows) do
		local pos = vim.api.nvim_buf_get_extmark_by_id(buf, palette_ns, mark, {})
		local row = pos and pos[1]
		local line = row and lines[row + 1]
		if line and line:find(meta.hex, 1, true) then
			local label = vim.trim(line:sub(meta.label_start + 1))
			if label ~= (meta.item.label or "") and store.rename(meta.item, label) then
				meta.item.label = label ~= "" and label or nil
				changed = changed + 1
			end
		end
	end
	vim.bo[buf].modified = false

	if not quiet then
		if changed == 0 then
			notify("No palette label changes")
		elseif changed == 1 then
			notify("Saved 1 palette label")
		else
			notify(("Saved %d palette labels"):format(changed))
		end
	end
	return true
end

-- ── Item resolution ──────────────────────────────────────────────────────────

---Return the store item under the cursor in a palette window.
---@param win ChromaWindow
---@return table?
local function palette_current_item(win)
	local model = palette_buffers[win.buf]
	if not (model and win.win and vim.api.nvim_win_is_valid(win.win)) then
		return nil
	end

	local cursor_row = vim.api.nvim_win_get_cursor(win.win)[1] - 1
	local line = vim.api.nvim_buf_get_lines(win.buf, cursor_row, cursor_row + 1, false)[1] or ""
	for mark, meta in pairs(model.rows) do
		local pos = vim.api.nvim_buf_get_extmark_by_id(win.buf, palette_ns, mark, {})
		if pos and pos[1] == cursor_row and line:find(meta.hex, 1, true) then
			return meta.item
		end
	end
	return nil
end

-- ── Palette actions ──────────────────────────────────────────────────────────

---@param win ChromaWindow
local function palette_close(win)
	if win.buf and vim.api.nvim_buf_is_valid(win.buf) and vim.bo[win.buf].modified then
		notify("Use :w to save palette label changes or :q! to discard", "warn")
		return
	end
	win:close()
end

---@param win ChromaWindow
---@param opts table
local function palette_use(win, opts)
	local item = palette_current_item(win)
	if not item then
		notify("Move the cursor to a color row", "warn")
		return
	end
	if vim.bo[win.buf].modified then
		palette_save_buffer(win.buf, true)
	end

	local hex = item.hex
	win:close()
	vim.schedule(function()
		-- Lazy-require to avoid circular dependency at load time.
		local open_fn = require("chroma").open
		if opts.state and opts.state:is_open() then
			opts.state:set_color(hex, "hex")
		else
			open_fn({ value = hex, format = "hex" })
		end
	end)
end

---@param win ChromaWindow
local function palette_copy(win)
	local item = palette_current_item(win)
	if not item then
		notify("Move the cursor to a color row", "warn")
		return
	end
	copy_to_clipboard(item.hex)
	store.add_recent(item.hex)
	notify("Copied " .. item.hex)
end

---@param win ChromaWindow
local function palette_delete(win)
	local item = palette_current_item(win)
	if not item then
		notify("Move the cursor to a color row", "warn")
		return
	end
	if vim.bo[win.buf].modified then
		palette_save_buffer(win.buf, true)
	end
	local cursor_lnum = vim.api.nvim_win_get_cursor(win.win)[1]
	if store.remove(item) then
		notify("Removed " .. item.hex)
		palette_render(win, palette_buffers[win.buf].opts, cursor_lnum)
	end
end

-- ── Public API ───────────────────────────────────────────────────────────────

---Open the palette/recent-color manager.
---
---The palette is a normal modifiable buffer: edit labels directly with Vim's
---text-editing commands and write the buffer (`:w`) to persist the renames.
---Confirming an item sends it to the active color picker when one is open;
---otherwise it opens a new picker seeded with that color so the user can still
---convert, copy or insert it.
---@param opts? { state?: ChromaState, recents_only?: boolean }
function M.open(opts)
	opts = opts or {}
	hl_mod.ensure()
	local items = palette_items(opts.recents_only)
	if #items == 0 then
		notify("No saved colors yet", "warn")
		return
	end

	local title = opts.recents_only and "Recent Colors" or "Color Palettes"
	window
		.new({
			show = false,
			text = { "" },
			ft = "chroma_palette",
			title = "󰏘  " .. title,
			title_pos = "center",
			footer = palette_footer(),
			footer_pos = "center",
			backdrop = false,
			zindex = 80,
			width = geo.PALETTE_WIDTH,
			height = math.min(24, math.max(8, #items + 3)),
			keys = {
				q = { palette_close, desc = "Close" },
				["<esc>"] = { palette_close, desc = "Close" },
				["<cr>"] = {
					function(win)
						palette_use(win, opts)
					end,
					desc = "Use",
				},
				y = { palette_copy, desc = "Copy" },
				D = { palette_delete, desc = "Delete" },
				["?"] = {
					function(win)
						win:toggle_help({ col_width = 22, key_width = 10 })
					end,
					desc = "Help",
				},
			},
			bo = {
				buftype = "acwrite",
				bufhidden = "wipe",
				filetype = "chroma_palette",
				modifiable = true,
				readonly = false,
				swapfile = false,
			},
			on_buf = function(win)
				pcall(
					vim.api.nvim_buf_set_name,
					win.buf,
					("chroma://palette/%s-%d"):format(opts.recents_only and "recents" or "palettes", win.id)
				)
				palette_render(win, opts)
				vim.api.nvim_create_autocmd("BufWriteCmd", {
					group = win.augroup,
					buffer = win.buf,
					callback = function()
						palette_save_buffer(win.buf)
					end,
				})
			end,
			on_close = function(win)
				palette_buffers[win.buf] = nil
			end,
		})
		:show()
end

return M
