# chroma.nvim

A Neovim color picker extracted from Max's dotfiles.

## Features

- Interactive RGB/HSL/alpha color picker
- Open from the color under the cursor or a visual selection
- Convert and copy color formats
- Recent colors and named palettes
- Self-contained floating UI with no runtime plugin dependencies

## Requirements

- Neovim 0.10+

## Installation

### lazy.nvim

```lua
{
  "max/chroma.nvim",
  opts = {
    store = {
      max_recents = 40,
    },
  },
}
```

For local development:

```lua
{
  "chroma.nvim",
  dir = vim.fn.expand("~/Projects/chroma.nvim"),
  opts = {},
}
```

## Commands

- `:ColorPicker [color]` - open the picker, optionally seeded with a color
- `:ColorPickerCursor` - open the picker for the color under cursor/selection
- `:ColorPickerInput` - prompt for a color string
- `:ColorPickerPalettes` - open saved palettes
- `:ColorPickerRecents` - open recent colors
- `:ColorPickerCopy [format]` - copy the color under cursor/selection

## Lua API

```lua
local chroma = require("chroma")

chroma.setup({
  store = { max_recents = 40 },
})

chroma.open()
chroma.open({ value = "#ff00ff" })
chroma.open_under_cursor({ selection = false })
chroma.copy_under_cursor({ format = "hex" })
chroma.palettes()
```

## Development

Run the headless test suite with:

```sh
nvim --headless -u tests/minimal_init.lua -c 'luafile tests/run.lua' -c 'qa'
```
