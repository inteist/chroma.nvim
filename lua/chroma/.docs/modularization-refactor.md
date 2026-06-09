# Color Picker Refactoring Walkthrough

## What changed

The **1,480-line** [ui.lua](file:///Users/max/dotconfig/nvim/lua/core/color_picker/ui.lua) monolith was split into **5 focused modules**, a shared utility module was extracted, and Lua diagnostic warnings were fixed across the codebase.

### New module structure

| Module | Lines | Responsibility |
|--------|------:|----------------|
| [util.lua](file:///Users/max/dotconfig/nvim/lua/core/color_picker/util.lua) | 96 | Shared helpers: `notify`, `get_snacks`, `copy_to_clipboard`, `align`, `theme_color`, `set_hl` |
| [geometry.lua](file:///Users/max/dotconfig/nvim/lua/core/color_picker/geometry.lua) | 171 | Color field grid math, slider math, hue sections, named constants |
| [highlights.lua](file:///Users/max/dotconfig/nvim/lua/core/color_picker/highlights.lua) | 129 | All `Chroma*` highlight group creation and management |
| [state.lua](file:///Users/max/dotconfig/nvim/lua/core/color_picker/state.lua) | 710 | `State` class: color manipulation, format cycling, editor preview, confirm/cancel |
| [render.lua](file:///Users/max/dotconfig/nvim/lua/core/color_picker/render.lua) | 364 | Picker window: Snacks.win lifecycle, keymap wiring, line-by-line rendering |
| [palette.lua](file:///Users/max/dotconfig/nvim/lua/core/color_picker/palette.lua) | 383 | Palette/recents browser window with inline label editing |

### Modified existing modules

| Module | Change |
|--------|--------|
| [color.lua](file:///Users/max/dotconfig/nvim/lua/core/color_picker/color.lua) | Renamed `color` parameters to `c` in 11 public functions to eliminate lua-language-server shadowing warnings |
| [store.lua](file:///Users/max/dotconfig/nvim/lua/core/color_picker/store.lua) | Replaced duplicated `notify()` + `_G.Snacks` global access with shared `util.notify` |
| [init.lua](file:///Users/max/dotconfig/nvim/lua/core/color_picker/init.lua) | Rewired from `ui.lua` to new module structure; public API unchanged |

### Deleted

| File | Reason |
|------|--------|
| `ui.lua` (1,480 lines) | Replaced by `state.lua` + `render.lua` + `palette.lua` + `highlights.lua` + `geometry.lua` |

## Key design decisions

1. **`State:render()` is a swappable stub**: The state module defines `State:render()` as a no-op. When `render.show()` creates the window, it overwrites `state:render()` with the real renderer. This cleanly breaks the circular dependency between state mutations (which trigger re-renders) and the rendering module (which reads state).

2. **Lazy `require` in palette.lua**: The `palette_use()` function calls `require("chroma").open` inside a `vim.schedule` callback instead of at the top of the file, avoiding a circular `init → palette → init` dependency at load time.

3. **Named constants in geometry.lua**: Magic numbers like `84` (layout width), `30` (preview width), `34` (picker height), `82` (palette width) are now `geo.LAYOUT_WIDTH`, `geo.PREVIEW_WIDTH`, etc.

## Lua warnings fixed

- **Shadowed `color` parameter** in 11 functions in `color.lua` → renamed to `c`
- **Undefined global `Snacks`** in `store.lua:39-40` → replaced with shared `util.notify()`
- **Forward-declared-then-reassigned locals** (`discrete_hue`, `color_field_position`, etc.) → moved to `geometry.lua` as proper module functions
- **Unused `palette_win` variable** → inlined the `.new(...):show()` call

## What was tested

- ✅ `require('chroma')` loads successfully
- ✅ `setup()` completes without errors
- ✅ All 6 `ColorPicker*` user commands register
- ✅ Full Neovim startup completes cleanly
- ✅ All 7 public API functions (`open`, `palettes`, `input`, `open_under_cursor`, `copy_under_cursor`, `current`, `set_highlights`) are present and callable
- ✅ `dotter deploy --verbose` applied: removed old `ui.lua` symlink, created 5 new symlinks
