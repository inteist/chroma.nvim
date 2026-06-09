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
	local before_palette = "  " .. swatch .. " │ "
	local palette_text = align(item.palette, 18)
	local before_hex = before_palette .. palette_text .. " │ "
	local hex_text = align(hex, 10)
	local prefix = before_hex .. hex_text .. " │ "

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
		div1_start = #before_palette - 4,
		div1_end = #before_palette - 1,
		div2_start = #before_hex - 4,
		div2_end = #before_hex - 1,
		div3_start = #prefix - 4,
		div3_end = #prefix - 1,
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
		{ " r ", "ChromaFooterKey" },
		{ " rename ", "ChromaFooterDesc" },
		{ " p ", "ChromaFooterKey" },
		{ " move ", "ChromaFooterDesc" },
		{ " dd ", "ChromaFooterKey" },
		{ " delete ", "ChromaFooterDesc" },
		{ " q ", "ChromaFooterKey" },
		{ " close ", "ChromaFooterDesc" },
		{ " ", "ChromaFooter" },
	}
end

-- ── Floating Input Prompt ───────────────────────────────────────────────────

---Open a sleek, 1-line floating input window styled like the plugin window.
---@param opts { prompt?: string, default?: string }
---@param on_confirm fun(value?: string)
local function input_prompt(opts, on_confirm)
	opts = opts or {}
	local win
	win = window.new({
		width = 40,
		height = 1,
		title = " " .. (opts.prompt or "Input") .. " ",
		title_pos = "center",
		border = "rounded",
		text = { opts.default or "" },
		backdrop = false,
		zindex = 95,
		keys = {
			["<cr>"] = {
				function(current)
					local val = vim.api.nvim_buf_get_lines(current.buf, 0, 1, false)[1] or ""
					current:close()
					vim.cmd("stopinsert")
					on_confirm(val)
				end,
				desc = "Confirm",
			},
			["<esc>"] = {
				function(current)
					current:close()
					vim.cmd("stopinsert")
					on_confirm(nil)
				end,
				desc = "Cancel",
			},
			q = {
				function(current)
					current:close()
					vim.cmd("stopinsert")
					on_confirm(nil)
				end,
				desc = "Cancel",
			},
		},
		bo = {
			buftype = "",
			bufhidden = "wipe",
			swapfile = false,
			modifiable = true,
		},
		on_buf = function(current)
			vim.keymap.set("i", "<cr>", function()
				local val = vim.api.nvim_buf_get_lines(current.buf, 0, 1, false)[1] or ""
				current:close()
				vim.cmd("stopinsert")
				on_confirm(val)
			end, { buffer = current.buf, silent = true })

			vim.keymap.set("i", "<esc>", function()
				current:close()
				vim.cmd("stopinsert")
				on_confirm(nil)
			end, { buffer = current.buf, silent = true })
		end,
		on_win = function(current)
			vim.api.nvim_win_set_cursor(current.win, { 1, #(opts.default or "") })
			vim.cmd("startinsert!")
		end,
	})
end

-- ── Palette actions ──────────────────────────────────────────────────────────

---@param win ChromaWindow
local function palette_rename(win)
	local item = palette_current_item(win)
	if not item then
		notify("Move the cursor to a color row", "warn")
		return
	end

	local cursor_lnum = vim.api.nvim_win_get_cursor(win.win)[1]

	input_prompt({
		prompt = "Rename label",
		default = item.label or "",
	}, function(new_label)
		if not new_label then
			return
		end
		if store.rename(item, new_label) then
			notify("Updated label: " .. (new_label ~= "" and new_label or "[empty]"))
			palette_render(win, palette_buffers[win.buf].opts, cursor_lnum)
		end
	end)
end

---@param win ChromaWindow
local function palette_move(win)
	local item = palette_current_item(win)
	if not item then
		notify("Move the cursor to a color row", "warn")
		return
	end

	local cursor_lnum = vim.api.nvim_win_get_cursor(win.win)[1]

	input_prompt({
		prompt = "Move to palette",
		default = item.scope == "recent" and "Custom" or item.palette,
	}, function(new_palette)
		if not new_palette or vim.trim(new_palette) == "" then
			return
		end
		if store.move_to_palette(item, new_palette) then
			notify("Moved to palette: " .. new_palette)
			palette_render(win, palette_buffers[win.buf].opts, cursor_lnum)
		end
	end)
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
	local h_prefix1 = "     │ "
	local h_prefix2 = h_prefix1 .. align("Palette", 18) .. " │ "
	local h_prefix3 = h_prefix2 .. align("Hex", 10) .. " │ "
	local header = h_prefix3 .. "Label"
	local lines = { header, "" }
	local hls = {
		{ row = 0, start_col = 0, end_col = #header, hl = "ChromaNormal" },
		{ row = 0, start_col = #h_prefix1 - 4, end_col = #h_prefix1 - 1, hl = "ChromaBorder" },
		{ row = 0, start_col = #h_prefix2 - 4, end_col = #h_prefix2 - 1, hl = "ChromaBorder" },
		{ row = 0, start_col = #h_prefix3 - 4, end_col = #h_prefix3 - 1, hl = "ChromaBorder" },
		{ row = 0, start_col = #h_prefix1, end_col = #h_prefix2 - 4, hl = "ChromaSelectorTitle" },
		{ row = 0, start_col = #h_prefix2, end_col = #h_prefix3 - 4, hl = "ChromaSelectorTitle" },
		{ row = 0, start_col = #h_prefix3, end_col = #header, hl = "ChromaSelectorTitle" },
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
		hls[#hls + 1] = {
			row = row,
			start_col = rendered.div1_start,
			end_col = rendered.div1_end,
			hl = "ChromaBorder",
		}
		hls[#hls + 1] = {
			row = row,
			start_col = rendered.div2_start,
			end_col = rendered.div2_end,
			hl = "ChromaBorder",
		}
		hls[#hls + 1] = {
			row = row,
			start_col = rendered.div3_start,
			end_col = rendered.div3_end,
			hl = "ChromaBorder",
		}
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
	vim.bo[buf].modifiable = false

	if win.win and vim.api.nvim_win_is_valid(win.win) then
		local lnum = math.min(math.max(cursor_lnum or model.first_lnum, model.first_lnum), #lines)
		vim.api.nvim_win_set_cursor(win.win, { lnum, model.first_label_start })
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
	local cursor_lnum = vim.api.nvim_win_get_cursor(win.win)[1]
	if store.remove(item) then
		notify("Removed " .. item.hex)
		palette_render(win, palette_buffers[win.buf].opts, cursor_lnum)
	end
end

-- ── Public API ───────────────────────────────────────────────────────────────

---Open the palette/recent-color manager.
---
---The palette is a read-only floating selector: rename labels using `r`, move
---items between palettes using `p`, and delete items using `dd`. Confirming
---an item sends it to the active color picker when one is open; otherwise
---it opens a new picker seeded with that color.
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
				yy = { palette_copy, desc = "Copy" },
				D = { palette_delete, desc = "Delete" },
				dd = { palette_delete, desc = "Delete" },
				r = { palette_rename, desc = "Rename Label" },
				e = { palette_rename, desc = "Rename Label" },
				p = { palette_move, desc = "Move Palette" },
				m = { palette_move, desc = "Move Palette" },
				["?"] = {
					function(win)
						win:toggle_help({ col_width = 22, key_width = 10 })
					end,
					desc = "Help",
				},
			},
			bo = {
				buftype = "nofile",
				bufhidden = "wipe",
				filetype = "chroma_palette",
				modifiable = false,
				readonly = false,
				swapfile = false,
			},
			wo = {
				cursorline = true,
			},
			on_buf = function(win)
				pcall(
					vim.api.nvim_buf_set_name,
					win.buf,
					("chroma://palette/%s-%d"):format(opts.recents_only and "recents" or "palettes", win.id)
				)
				palette_render(win, opts)
			end,
			on_close = function(win)
				palette_buffers[win.buf] = nil
			end,
		})
		:show()
end

return M
