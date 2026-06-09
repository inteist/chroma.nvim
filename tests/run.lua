local failures = {}
local tests = {}

local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function fail(message)
	error(message, 2)
end

local function assert_true(value, message)
	if not value then
		fail(message or "expected value to be truthy")
	end
end

local function assert_false(value, message)
	if value then
		fail(message or "expected value to be falsey")
	end
end

local function assert_eq(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		fail(
			(message or "values differ")
				.. "\nexpected: "
				.. vim.inspect(expected)
				.. "\nactual:   "
				.. vim.inspect(actual)
		)
	end
end

local function valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

test("utility helpers use native Neovim APIs", function()
	local util = require("chroma.util")
	vim.api.nvim_set_hl(0, "ChromaTestHighlight", { fg = "#112233", bg = "#445566" })
	assert_eq("#112233", util.theme_color("ChromaTestHighlight", "fg", "#000000"))
	assert_eq("#445566", util.theme_color("ChromaTestHighlight", "bg", "#000000"))
	assert_eq("#abcdef", util.theme_color("ChromaMissingHighlight", "fg", "#abcdef"))

	local calls = {}
	local throttled = util.throttle(function(value)
		calls[#calls + 1] = value
	end, 20)
	throttled("first")
	throttled("second")
	throttled("third")
	vim.wait(100, function()
		return #calls >= 2
	end)
	assert_eq("first", calls[1], "throttle should invoke the leading call immediately")
	assert_eq("third", calls[#calls], "throttle should replay the latest queued call")
	assert_true(#calls <= 2, "throttle should coalesce calls during the cooldown")
end)

test("input prompts delegate to vim.ui.input", function()
	local input = require("chroma.input")
	local original = vim.ui.input
	local seen_opts
	local result
	vim.ui.input = function(opts, callback)
		seen_opts = opts
		callback("#abcdef")
	end

	input.prompt({ prompt = "Color value", default = "#000000" }, function(value)
		result = value
	end)

	vim.ui.input = original
	assert_eq("Color value", seen_opts.prompt)
	assert_eq("#000000", seen_opts.default)
	assert_eq("#abcdef", result)
end)

test("window helper manages lifecycle, keymaps, title, and help", function()
	require("chroma.highlights").set_highlights()
	local window = require("chroma.window")
	local mapped = false
	local closed = false
	local win
	win = window.new({
		show = false,
		width = 40,
		height = 5,
		backdrop = false,
		text = { "hello" },
		title = "Test",
		footer = { { " q ", "ChromaFooterKey" } },
		keys = {
			q = {
				function(current)
					mapped = current == win
				end,
				desc = "Mark",
			},
			["?"] = {
				function(current)
					current:toggle_help({ col_width = 24, key_width = 8 })
				end,
				desc = "Help",
			},
		},
		on_close = function(current)
			closed = current == win
		end,
	})

	assert_false(win:valid(), "show=false should defer opening")
	win:show()
	assert_true(win:valid(), "window should be valid after show")
	assert_eq({ "hello" }, vim.api.nvim_buf_get_lines(win.buf, 0, -1, false))

	vim.api.nvim_win_call(win.win, function()
		vim.cmd("normal q")
	end)
	assert_true(mapped, "buffer-local keymap should receive the ChromaWindow instance")

	win:toggle_help({ col_width = 24, key_width = 8 })
	local help_win, help_buf = win.help_win, win.help_buf
	assert_true(valid_win(help_win), "help window should open")
	assert_true(valid_buf(help_buf), "help buffer should open")
	win:toggle_help()
	assert_false(valid_win(help_win), "second toggle should close help window")
	assert_false(valid_buf(help_buf), "second toggle should wipe help buffer")

	win:set_title("Renamed", "left")
	local config = vim.api.nvim_win_get_config(win.win)
	assert_eq("left", config.title_pos)

	local handle, buf = win.win, win.buf
	win:close()
	assert_true(closed, "close callback should run exactly once")
	assert_false(valid_win(handle), "content window should close")
	assert_false(valid_buf(buf), "owned scratch buffer should be wiped")
end)

test("palette manager opens with the built-in window helper", function()
	local store = require("chroma.store")
	store.setup({ path = vim.fn.tempname() })
	store.add_to_palette("Test", "#ff00ff", "Pink")

	require("chroma.palette").open()
	local palette_win, palette_buf
	for _, candidate in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(candidate)
		if vim.bo[buf].filetype == "chroma_palette" then
			palette_win, palette_buf = candidate, buf
			break
		end
	end

	assert_true(valid_win(palette_win), "palette floating window should open")
	assert_true(valid_buf(palette_buf), "palette buffer should open")
	local text = table.concat(vim.api.nvim_buf_get_lines(palette_buf, 0, -1, false), "\n")
	assert_true(text:find("#ff00ff", 1, true) ~= nil, "palette buffer should render stored colors")
	pcall(vim.api.nvim_win_close, palette_win, true)
end)

test("palette store supports moving colors between palettes", function()
	local store = require("chroma.store")
	store.setup({ path = vim.fn.tempname() })
	local entry = store.add_to_palette("SourcePalette", "#112233", "TestColor")

	local items = store.items()
	local item_to_move
	for _, item in ipairs(items) do
		if item.hex == "#112233" then
			item_to_move = item
			break
		end
	end
	assert_true(item_to_move ~= nil, "item should be found in store")

	local success = store.move_to_palette(item_to_move, "DestPalette")
	assert_true(success, "should successfully move color to new palette")

	local updated_items = store.items()
	local moved_item
	for _, item in ipairs(updated_items) do
		if item.hex == "#112233" then
			moved_item = item
			break
		end
	end
	assert_eq("DestPalette", moved_item.palette, "should be in DestPalette")
end)

test("palette buffer uses read-only mode and cursorline highlight", function()
	local store = require("chroma.store")
	store.setup({ path = vim.fn.tempname() })
	store.add_to_palette("Test", "#ff00ff", "Pink")

	require("chroma.palette").open()
	local palette_win, palette_buf
	for _, candidate in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(candidate)
		if vim.bo[buf].filetype == "chroma_palette" then
			palette_win, palette_buf = candidate, buf
			break
		end
	end

	assert_true(valid_win(palette_win), "palette window should open")
	assert_true(valid_buf(palette_buf), "palette buffer should open")
	assert_false(vim.bo[palette_buf].modifiable, "palette buffer should be read-only")
	assert_true(vim.wo[palette_win].cursorline, "palette window should have cursorline enabled")

	pcall(vim.api.nvim_win_close, palette_win, true)
end)

test("chroma opens without an external UI module", function()
	local dependency = "sn" .. "acks"
	local global_name = dependency:sub(1, 1):upper() .. dependency:sub(2)
	package.loaded[dependency] = nil
	_G[global_name] = nil

	local chroma = require("chroma")
	chroma.setup({
		store = { path = vim.fn.tempname() },
		insert_on_confirm = false,
		live_preview = false,
	})

	local state = chroma.open({ value = "#336699", insert_on_confirm = false, live_preview = false })
	assert_true(state:is_open(), "picker should open with the built-in window helper")
	assert_eq("chroma", vim.bo[state.win.buf].filetype)
	state:cancel()
	assert_false(state:is_open(), "picker should close cleanly")
end)

for _, item in ipairs(tests) do
	local ok, err = xpcall(item.fn, debug.traceback)
	if ok then
		io.stdout:write("✓ " .. item.name .. "\n")
	else
		failures[#failures + 1] = "✗ " .. item.name .. "\n" .. err
	end
end

if #failures > 0 then
	io.stdout:write(table.concat(failures, "\n") .. "\n")
	vim.cmd("cquit 1")
end

io.stdout:write(("%d tests passed\n"):format(#tests))
