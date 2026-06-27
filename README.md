# chroma.nvim

A self-contained, high-performance interactive color picker for Neovim 0.10+ extracted from Max's dotfiles.

Chroma provides a feature-rich, standalone floating UI to edit and preview color literals in your code in real-time, with **zero runtime plugin dependencies**.

---

## Features

- **Interactive Color Field**: Navigate a 60x12 saturation-value grid and adjust hue, saturation, lightness, red, green, blue, and alpha sliders with real-time updates.
- **Smart Target Detection**: Opens seeded with the color literal under your cursor or visual selection (supports CSS hex, rgb, rgba, hsl, hsla, hsv, and standard names).
- **Dual-Pane Palette & Recents Manager**: Browse and select from saved palettes or recents. Built with scroll and cursor linkage, enabling inline label editing and disk serialization.
- **Live Editor Replacements**: Highlights and replaces code color literals in the source buffer dynamically as you tweak values in the floating window.
- **Zero Dependencies**: Self-contained floating UI built on top of native Neovim APIs.

---

## Requirements

- Neovim 0.10+

---

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "inteist/chroma.nvim",
  opts = {
    store = {
      max_recents = 40, -- Limit of recently selected colors saved in store
    },
    default_color = "#7cd5ff", -- Default fallback color seed
    default_format = "hex",    -- Default fallback output format
    insert_on_confirm = true,  -- Automatically insert selected color on confirm
    live_preview = true,       -- Highlight/replace buffer color in real-time
  },
}
```

---

## Commands & Lua API

Chroma defines ergonomic user commands that mirror the Lua API for scriptability and command-line autocomplete.

### Commands Index

| Command                     | Description                                                 |
| :-------------------------- | :---------------------------------------------------------- |
| `:ColorPicker [color]`      | Open Chroma, optionally seeded with a custom color.         |
| `:ColorPickerCursor`        | Open picker for the color under the cursor or selection.    |
| `:ColorPickerInput`         | Prompt for a color string, then open the picker.            |
| `:ColorPickerPalettes`      | Open the saved color palettes manager.                      |
| `:ColorPickerRecents`       | Open recently used colors.                                  |
| `:ColorPickerCopy [format]` | Copy the color under cursor/selection in a specific format. |

### Lua API Examples

```lua
local chroma = require("chroma")

-- Initialize configurations
chroma.setup({
  store = { max_recents = 40 }
})

-- Lua functions
chroma.open()                                  -- Open with default seed
chroma.open({ value = "#ff00ff" })             -- Open seeded with color
chroma.open_under_cursor({ selection = false }) -- Open for color under cursor
chroma.copy_under_cursor({ format = "hex" })   -- Copy color under cursor as hex
chroma.palettes()                              -- Open palette manager
```

### Supported Formats

- **Input formats**: `#rrggbb`, `#rrggbbaa`, `0xrrggbb`, `0xaarrggbb`, `rgb()`, `rgba()`, `hsl()`, `hsla()`, `hsv()`, and standard CSS color names.
- **Output formats**: `hex` (`#rrggbb`), `hexa` (`#rrggbbaa`), `rgb0x` (`0xrrggbb`), `argb0x` (`0xaarrggbb`), `rgb`, `rgba`, `hsl`, `hsla`, `hsv`.

---

## Keyboard Navigation

### Main Color Picker UI

| Keys                  | Action                                                                       |
| :-------------------- | :--------------------------------------------------------------------------- |
| `h` / `j` / `k` / `l` | Move cursor in saturation-value grid / adjust channel values                 |
| `←` / `↓` / `↑` / `→` | Move cursor in saturation-value grid / adjust channel values                 |
| `<Tab>`               | Cycle focus between the Color Field and channel sliders                      |
| `H` / `S` / `L`       | Directly focus Hue, Saturation, or Lightness sliders                         |
| `R` / `G` / `B`       | Directly focus Red, Green, or Blue sliders                                   |
| `A`                   | Directly focus the Alpha (transparency) slider                               |
| `f`                   | Cycle active color output format                                             |
| `i`                   | Prompt to type a custom color value manually                                 |
| `y`                   | Yank the active color in the current format to the clipboard                 |
| `<CR>` (Enter)        | Confirm selection (saves color to recents, replaces code literal, and exits) |
| `q` / `<Esc>`         | Wipout floating buffer and cancel picker                                     |

### Palette & Recents Manager UI

| Keys                   | Action                                                                |
| :--------------------- | :-------------------------------------------------------------------- |
| `<Tab>`                | Cycle focus between Left (color list) and Right (labels list) panes   |
| `j` / `k` or `↓` / `↑` | Navigate colors (scrolls and moves cursor in left/right pane in sync) |
| `i` / `A`              | Trigger edit mode on focused label inside the right pane              |
| `:w`                   | Save modified label strings to JSON file on disk                      |
| `y`                    | Yank the color of the selected entry directly to the clipboard        |
| `<CR>` (Enter)         | Load selected color back into the main color picker UI                |
| `q` / `<Esc>`          | Close the palettes manager                                            |

---

## Highlight Groups

Chroma sets up custom semantic highlight groups that automatically sync on colorscheme switches. You can override these in your configuration:

| Highlight Group    | Default Link / Description                               |
| :----------------- | :------------------------------------------------------- |
| `ChromaNormal`     | Links to `NormalFloat` (Main panel background and text)  |
| `ChromaBorder`     | Links to `FloatBorder` (Panel border outline)            |
| `ChromaTitle`      | Links to `FloatTitle` (Header titles)                    |
| `ChromaAccent`     | Links to `Directory` (Focus markers and selector checks) |
| `ChromaActive`     | Links to `PmenuSel` (Focused channel labels)             |
| `ChromaValue`      | Links to `Number` (Channel numeric values)               |
| `ChromaMuted`      | Links to `Comment` (Dimmed instructions and subtitles)   |
| `ChromaFooterKey`  | Links to `Keyword` (Keyboard shortcut letters in footer) |
| `ChromaFooterDesc` | Links to `Comment` (Shortcut description text in footer) |

---

## Codebase Architecture

For developers and contributors, the plugin's code is divided into modular, single-responsibility files:

- `init.lua`: Main entry point. Exposes public Lua APIs and creates `:ColorPicker*` commands.
- `state.lua`: Manages the color picker state machine and detects/locates colors in source buffers.
- `color.lua`: Core color parser and mathematical converter (Hex, RGB, HSL, HSV, alpha, and names).
- `render.lua`: Builds and draws lines for the color picker grid, sliders, and formats.
- `palette.lua`: Implements the scrollbinded dual-pane floating layout for saved palettes.
- `window.lua`: Ergonomic utility creating floating windows, backdrop overlays, and key help popups.
- `store.lua`: Handles loading and serializing user saved palettes and recents history to JSON.
- `geometry.lua`: Math mapper translating coordinates to color saturation, value, and discrete hues.
- `highlights.lua`: Setup and auto-synchronization of highlight groups on colorscheme updates.
- `util.lua`: Internal helper utilities (clipboard copy, throttling, window options, notifications).
- `input.lua`: Thin, safe wrapper for standard `vim.ui.input` prompt.

---

## Development

Run the headless unit test suite using Neovim:

```sh
nvim --headless -u tests/minimal_init.lua -c 'luafile tests/run.lua' -c 'qa'
```
