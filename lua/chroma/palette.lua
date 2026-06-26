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

-- ── Local helper to apply option values ──────────────────────────────────────
local function apply_options(scope, handle, options)
	for name, value in pairs(options or {}) do
		local target = {}
		target[scope] = handle
		pcall(vim.api.nvim_set_option_value, name, value, target)
	end
end

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
		{ " tab ", "ChromaFooterKey" },
		{ " switch pane ", "ChromaFooterDesc" },
		{ " enter ", "ChromaFooterKey" },
		{ " use ", "ChromaFooterDesc" },
		{ " y ", "ChromaFooterKey" },
		{ " copy ", "ChromaFooterDesc" },
		{ " :w ", "ChromaFooterKey" },
		{ " save labels ", "ChromaFooterDesc" },
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

-- ── Item resolution ──────────────────────────────────────────────────────────

---Return the store item under the cursor in a palette window.
---@param win ChromaWindow
---@return table?
local function palette_current_item(win)
	local right_buf = win.right_buf
	local right_win = win.right_win
	local model = palette_buffers[right_buf]
	if not (model and right_win and vim.api.nvim_win_is_valid(right_win)) then
		return nil
	end

	local cursor_row = vim.api.nvim_win_get_cursor(right_win)[1] - 1
	for mark, meta in pairs(model.rows) do
		local pos = vim.api.nvim_buf_get_extmark_by_id(right_buf, palette_ns, mark, {})
		if pos and pos[1] == cursor_row then
			return meta.item
		end
	end
	return nil
end

-- Forward-declared render helper
local palette_render

-- ── Palette actions ──────────────────────────────────────────────────────────

---@param win ChromaWindow
local function palette_close(win)
	if win.closing then
		return
	end
	win.closing = true

	local left_win = win.left_win
	local right_win = win.right_win
	local left_buf = win.left_buf
	local right_buf = win.right_buf

	win.left_win = nil
	win.right_win = nil
	win.left_buf = nil
	win.right_buf = nil

	if win.palette_group then
		pcall(vim.api.nvim_del_augroup_by_id, win.palette_group)
		win.palette_group = nil
	end

	if left_win and vim.api.nvim_win_is_valid(left_win) then
		pcall(vim.api.nvim_win_close, left_win, true)
	end
	if right_win and vim.api.nvim_win_is_valid(right_win) then
		pcall(vim.api.nvim_win_close, right_win, true)
	end
	if left_buf and vim.api.nvim_buf_is_valid(left_buf) then
		palette_buffers[left_buf] = nil
		pcall(vim.api.nvim_buf_delete, left_buf, { force = true })
	end
	if right_buf and vim.api.nvim_buf_is_valid(right_buf) then
		palette_buffers[right_buf] = nil
		pcall(vim.api.nvim_buf_delete, right_buf, { force = true })
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

	local hex = item.hex
	palette_close(win)
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
	local cursor_lnum = win.right_win and vim.api.nvim_win_is_valid(win.right_win) and vim.api.nvim_win_get_cursor(win.right_win)[1] or nil
	if store.remove(item) then
		notify("Removed " .. item.hex)
		palette_render(win, palette_buffers[win.right_buf].opts, cursor_lnum)
	end
end

---@param win ChromaWindow
local function palette_rename(win)
	local item = palette_current_item(win)
	if not item then
		notify("Move the cursor to a color row", "warn")
		return
	end

	local cursor_lnum = win.right_win and vim.api.nvim_win_is_valid(win.right_win) and vim.api.nvim_win_get_cursor(win.right_win)[1] or nil

	input_prompt({
		prompt = "Rename label",
		default = item.label or "",
	}, function(new_label)
		if not new_label then
			return
		end
		if store.rename(item, new_label) then
			notify("Updated label: " .. (new_label ~= "" and new_label or "[empty]"))
			palette_render(win, palette_buffers[win.right_buf].opts, cursor_lnum)
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

	local cursor_lnum = win.right_win and vim.api.nvim_win_is_valid(win.right_win) and vim.api.nvim_win_get_cursor(win.right_win)[1] or nil

	input_prompt({
		prompt = "Move to palette",
		default = item.scope == "recent" and "Custom" or item.palette,
	}, function(new_palette)
		if not new_palette or vim.trim(new_palette) == "" then
			return
		end
		if store.move_to_palette(item, new_palette) then
			notify("Moved to palette: " .. new_palette)
			palette_render(win, palette_buffers[win.right_buf].opts, cursor_lnum)
		end
	end)
end

---Save labels edited directly in the buffer.
---@param win ChromaWindow
local function palette_save_labels(win)
	local right_buf = win.right_buf
	local model = palette_buffers[right_buf]
	if not (model and vim.api.nvim_buf_is_valid(right_buf)) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(right_buf, 0, -1, false)

	local items_count = 0
	for _ in pairs(model.rows) do
		items_count = items_count + 1
	end

	if #lines ~= items_count + 2 then
		notify("Cannot save: line count mismatch. Please reload or undo edits.", "error")
		return
	end

	local changed = 0
	for mark, meta in pairs(model.rows) do
		local pos = vim.api.nvim_buf_get_extmark_by_id(right_buf, palette_ns, mark, {})
		local row = pos and pos[1]
		local line = row and lines[row + 1]
		if line then
			local label = vim.trim(line)
			if label ~= (meta.item.label or "") and store.rename(meta.item, label) then
				meta.item.label = label ~= "" and label or nil
				changed = changed + 1
			end
		end
	end

	if changed > 0 then
		notify(("Saved %d palette labels"):format(changed))
	else
		notify("No palette label changes")
	end

	local cursor_lnum = win.right_win and vim.api.nvim_win_is_valid(win.right_win) and vim.api.nvim_win_get_cursor(win.right_win)[1] or nil
	palette_render(win, model.opts, cursor_lnum)
end

-- ── Buffer rendering ─────────────────────────────────────────────────────────

---Render the palette items into the buffer.
---@param win ChromaWindow
---@param opts table
---@param cursor_lnum? number
---@return boolean
palette_render = function(win, opts, cursor_lnum)
	local left_buf = win.left_buf
	local right_buf = win.right_buf
	if not (left_buf and right_buf and vim.api.nvim_buf_is_valid(left_buf) and vim.api.nvim_buf_is_valid(right_buf)) then
		return false
	end

	local items = palette_items(opts.recents_only)
	if #items == 0 then
		palette_buffers[left_buf] = nil
		palette_buffers[right_buf] = nil
		notify("No saved colors yet", "warn")
		palette_close(win)
		return false
	end

	local title = opts.recents_only and "Recent Colors" or "Color Palettes"
	local h_prefix1 = "     │ "
	local h_prefix2 = h_prefix1 .. align("Palette", 18) .. " │ "
	local h_prefix3 = h_prefix2 .. align("Hex", 10) .. " │ "

	local left_header = h_prefix3
	local right_header = "Label"

	local left_lines = { left_header, "" }
	local right_lines = { right_header, "" }

	local hls = {
		{ row = 0, start_col = 0, end_col = #left_header, hl = "ChromaNormal" },
		{ row = 0, start_col = #h_prefix1 - 4, end_col = #h_prefix1 - 1, hl = "ChromaBorder" },
		{ row = 0, start_col = #h_prefix2 - 4, end_col = #h_prefix2 - 1, hl = "ChromaBorder" },
		{ row = 0, start_col = #h_prefix3 - 4, end_col = #h_prefix3 - 1, hl = "ChromaBorder" },
		{ row = 0, start_col = #h_prefix1, end_col = #h_prefix2 - 4, hl = "ChromaSelectorTitle" },
		{ row = 0, start_col = #h_prefix2, end_col = #h_prefix3 - 4, hl = "ChromaSelectorTitle" },
	}
	local right_hls = {
		{ row = 0, start_col = 0, end_col = #right_header, hl = "ChromaSelectorTitle" },
	}
	local pending = {}

	for _, item in ipairs(items) do
		local rendered = palette_line(item)
		local row = #left_lines
		left_lines[row + 1] = rendered.prefix
		right_lines[row + 1] = " " .. (item.label or "")

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
			right_hls[#right_hls + 1] = { row = row, start_col = 1, end_col = 1 + #item.label, hl = "ChromaMuted" }
		end
		pending[#pending + 1] = {
			row = row,
			item = item,
			hex = rendered.hex,
		}
	end

	vim.bo[left_buf].modifiable = true
	vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, left_lines)
	vim.api.nvim_buf_clear_namespace(left_buf, palette_ns, 0, -1)
	for _, h in ipairs(hls) do
		vim.api.nvim_buf_add_highlight(left_buf, palette_ns, h.hl, h.row, h.start_col, h.end_col)
	end
	vim.bo[left_buf].modifiable = false

	vim.bo[right_buf].modifiable = true
	vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, right_lines)
	vim.api.nvim_buf_clear_namespace(right_buf, palette_ns, 0, -1)
	for _, h in ipairs(right_hls) do
		vim.api.nvim_buf_add_highlight(right_buf, palette_ns, h.hl, h.row, h.start_col, h.end_col)
	end
	vim.bo[right_buf].modifiable = true
	vim.bo[right_buf].modified = false

	local model = palette_buffers[right_buf] or {
		title = title,
		opts = opts,
		rows = {},
		first_lnum = 3,
	}
	model.rows = {}
	for _, meta in ipairs(pending) do
		local left_mark = vim.api.nvim_buf_set_extmark(left_buf, palette_ns, meta.row, 0, { right_gravity = false })
		local right_mark = vim.api.nvim_buf_set_extmark(right_buf, palette_ns, meta.row, 0, { right_gravity = false })
		model.rows[right_mark] = {
			item = meta.item,
			hex = meta.hex,
			left_mark = left_mark,
		}
	end
	palette_buffers[left_buf] = model
	palette_buffers[right_buf] = model

	local lnum = math.min(math.max(cursor_lnum or model.first_lnum, model.first_lnum), #left_lines)
	if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
		vim.api.nvim_win_set_cursor(win.left_win, { lnum, 0 })
	end
	if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then
		vim.api.nvim_win_set_cursor(win.right_win, { lnum, 1 })
	end
	return true
end

-- ── Keymap setup helpers ─────────────────────────────────────────────────────

local function setup_left_keys(win, opts)
	local left_buf = win.left_buf
	local map_opts = { buffer = left_buf, silent = true, nowait = true }

	vim.keymap.set("n", "q", function() palette_close(win) end, map_opts)
	vim.keymap.set("n", "<esc>", function() palette_close(win) end, map_opts)
	vim.keymap.set("n", "<cr>", function() palette_use(win, opts) end, map_opts)

	vim.keymap.set("n", "y", function() palette_copy(win) end, map_opts)
	vim.keymap.set("n", "yy", function() palette_copy(win) end, map_opts)

	vim.keymap.set("n", "dd", function() palette_delete(win) end, map_opts)
	vim.keymap.set("n", "D", function() palette_delete(win) end, map_opts)

	vim.keymap.set("n", "p", function() palette_move(win) end, map_opts)
	vim.keymap.set("n", "m", function() palette_move(win) end, map_opts)

	-- Tab to toggle focus to labels
	vim.keymap.set("n", "<tab>", function()
		if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then
			vim.api.nvim_set_current_win(win.right_win)
		end
	end, map_opts)

	-- Edit keys: switch to right pane and start editing
	local start_edit = function()
		if win.right_win and vim.api.nvim_win_is_valid(win.right_win) then
			vim.api.nvim_set_current_win(win.right_win)
			vim.cmd("startinsert!")
		end
	end
	vim.keymap.set("n", "r", start_edit, map_opts)
	vim.keymap.set("n", "e", start_edit, map_opts)
	vim.keymap.set("n", "i", start_edit, map_opts)
	vim.keymap.set("n", "a", start_edit, map_opts)

	vim.keymap.set("n", "?", function()
		win:toggle_help({ col_width = 22, key_width = 10 })
	end, map_opts)
end

local function setup_right_keys(win, opts)
	local right_buf = win.right_buf
	local map_opts = { buffer = right_buf, silent = true, nowait = true }

	vim.keymap.set("n", "q", function() palette_close(win) end, map_opts)
	vim.keymap.set("n", "<esc>", function() palette_close(win) end, map_opts)
	vim.keymap.set("n", "<cr>", function() palette_use(win, opts) end, map_opts)

	-- Tab to toggle focus back to details
	vim.keymap.set("n", "<tab>", function()
		if win.left_win and vim.api.nvim_win_is_valid(win.left_win) then
			vim.api.nvim_set_current_win(win.left_win)
		end
	end, map_opts)

	-- Vim editing restrictions to preserve row count and alignment
	vim.keymap.set("i", "<cr>", "<esc>jA", map_opts)
	vim.keymap.set("n", "o", "jA", map_opts)
	vim.keymap.set("n", "O", "kA", map_opts)
	vim.keymap.set("n", "dd", "0D", map_opts)

	vim.keymap.set("n", "?", function()
		win:toggle_help({ col_width = 22, key_width = 10 })
	end, map_opts)
end

-- ── Public API ───────────────────────────────────────────────────────────────

---Open the palette/recent-color manager.
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
	local items_count = #items
	local outer_height = math.min(24, math.max(8, items_count + 3))

	-- Create the outer rounded floating container window
	local outer_win = window.new({
		show = false,
		text = { "" },
		ft = "chroma_palette_outer",
		title = "󰏘  " .. title,
		title_pos = "center",
		footer = palette_footer(),
		footer_pos = "center",
		backdrop = false,
		zindex = 80,
		width = geo.PALETTE_WIDTH,
		height = outer_height,
		bo = {
			buftype = "nofile",
			bufhidden = "wipe",
			swapfile = false,
			modifiable = false,
		},
		on_close = function(win)
			palette_close(win)
		end,
	})

	outer_win:show()

	local inner_height = vim.api.nvim_win_get_height(outer_win.win)

	-- Create Left and Right buffers
	local left_buf = vim.api.nvim_create_buf(false, true)
	local right_buf = vim.api.nvim_create_buf(false, true)

	pcall(
		vim.api.nvim_buf_set_name,
		left_buf,
		("chroma://palette/%s-%d"):format(opts.recents_only and "recents" or "palettes", outer_win.id)
	)
	pcall(
		vim.api.nvim_buf_set_name,
		right_buf,
		("chroma://palette-labels/%s-%d"):format(opts.recents_only and "recents" or "palettes", outer_win.id)
	)

	apply_options("buf", left_buf, {
		buftype = "nofile",
		bufhidden = "wipe",
		filetype = "chroma_palette",
		modifiable = false,
		swapfile = false,
	})
	apply_options("buf", right_buf, {
		buftype = "acwrite",
		bufhidden = "wipe",
		filetype = "chroma_palette_labels",
		modifiable = true,
		swapfile = false,
	})

	-- Create child Left and Right windows inside outer container
	local left_win = vim.api.nvim_open_win(left_buf, true, {
		relative = "win",
		win = outer_win.win,
		row = 0,
		col = 0,
		width = 40,
		height = inner_height,
		style = "minimal",
		border = "none",
		focusable = true,
		zindex = 81,
	})

	local right_win = vim.api.nvim_open_win(right_buf, false, {
		relative = "win",
		win = outer_win.win,
		row = 0,
		col = 40,
		width = 40,
		height = inner_height,
		style = "minimal",
		border = "none",
		focusable = true,
		zindex = 81,
	})

	outer_win.left_win = left_win
	outer_win.left_buf = left_buf
	outer_win.right_win = right_win
	outer_win.right_buf = right_buf

	-- Create custom palette_group augroup
	local palette_group = vim.api.nvim_create_augroup("chroma_palette_lifecycle_" .. outer_win.id, { clear = true })
	outer_win.palette_group = palette_group

	for _, w in ipairs({ left_win, right_win }) do
		apply_options("win", w, {
			cursorline = true,
			winhighlight = "Normal:ChromaNormal,NormalNC:ChromaNormal",
		})
		vim.wo[w].scrollbind = true
		vim.wo[w].cursorbind = true
	end

	palette_buffers[left_buf] = {
		title = title,
		opts = opts,
		rows = {},
		first_lnum = 3,
	}
	palette_buffers[right_buf] = palette_buffers[left_buf]

	palette_render(outer_win, opts)

	vim.api.nvim_win_call(left_win, function()
		vim.cmd("syncbind")
	end)

	setup_left_keys(outer_win, opts)
	setup_right_keys(outer_win, opts)

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = palette_group,
		buffer = right_buf,
		callback = function()
			palette_save_labels(outer_win)
		end,
	})

	-- Enforce cursor row constraints (prevent cursor on rows 1 and 2)
	vim.api.nvim_create_autocmd({ "CursorMoved" }, {
		group = palette_group,
		buffer = left_buf,
		callback = function()
			if not vim.api.nvim_win_is_valid(left_win) then return end
			local cursor = vim.api.nvim_win_get_cursor(left_win)
			if cursor[1] < 3 then
				pcall(vim.api.nvim_win_set_cursor, left_win, { 3, 0 })
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = palette_group,
		buffer = right_buf,
		callback = function()
			if not vim.api.nvim_win_is_valid(right_win) then return end
			local cursor = vim.api.nvim_win_get_cursor(right_win)
			if cursor[1] < 3 then
				pcall(vim.api.nvim_win_set_cursor, right_win, { 3, math.max(1, cursor[2]) })
			end
		end,
	})

	-- Intercept child window closes to clean up outer/sibling windows
	vim.api.nvim_create_autocmd("WinClosed", {
		group = palette_group,
		pattern = { tostring(left_win), tostring(right_win) },
		callback = function()
			palette_close(outer_win)
		end,
	})
end

return M