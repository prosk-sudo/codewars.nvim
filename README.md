# codewars.nvim

Solve [Codewars](https://www.codewars.com) katas from within Neovim.

## Requirements

- Neovim >= 0.9.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) — HTTP requests, file operations
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) — UI components
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) — kata picker, language picker
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) with `markdown` parser — description rendering (optional)
- [markdown.nvim](https://github.com/tadmccorkle/markdown.nvim) — enhanced markdown rendering (optional)

## Installation

### lazy.nvim

```lua
{
    "prosk-sudo/codewars.nvim",
    lazy = false,
    dependencies = {
        "nvim-lua/plenary.nvim",
        "MunifTanjim/nui.nvim",
        "nvim-telescope/telescope.nvim",    -- kata picker / language picker
        -- optional
        "tadmccorkle/markdown.nvim",        -- markdown rendering in description
    },
    opts = {},
}
```

## Authentication

### Getting Your Cookies

1. Log in to [codewars.com](https://www.codewars.com) in your browser
2. Open **Developer Tools** (F12) → **Application** tab → **Cookies**
3. Find these two cookies for `www.codewars.com`:
   - `CSRF-TOKEN`
   - `_session_id`
4. Run `:CW cookie` in Neovim and paste them in this format:

```
CSRF-TOKEN=your_csrf_value; _session_id=your_session_value
```

Your cookies are stored locally at `~/.cache/nvim/codewars/cookie`.

## Usage

### Standalone Mode

Launch Neovim with the plugin argument to get a dashboard:

```bash
nvim codewars.nvim
```

### Available Commands

See [COMMANDS.md](COMMANDS.md) for the full list, or run `:CW help` inside Neovim.

### Example Workflow

```
:CW cookie               " paste your browser cookies (one-time setup)
:CW train multiply python
```

This opens the `8 kyu Multiply` kata with:
- Description split on the left (markdown)
- Code editor on the right (with template)
- Test cases split below the code editor

Write your solution, then:

```
:CW test        " Quick test with example cases
:CW attempt     " Full attempt with all test cases
:CW submit      " Submit after passing attempt
```

## Configuration

All settings are optional. See [CONFIGS.md](CONFIGS.md) for the full reference.

```lua
require("codewars").setup({})
```

## Current Issues

- Long test output lines (e.g. random test inputs with large data structures) may overflow the result popup. Neovim's `wrap` option is enabled but may not fully contain all content within NUI Layout popups.
- Some language icons in the picker may display as boxes or incorrect characters depending on your Nerd Font version and variant. Nerd Font v3 reorganized many codepoints, and not all patched fonts include every icon set (Devicons, Material Design, Seti-UI, etc.).

## Acknowledgements

This plugin was heavily inspired by [leetcode.nvim](https://github.com/kawre/leetcode.nvim) by [@kawre](https://github.com/kawre)!

Built and maintained with the help of [Claude Code](https://claude.ai/claude-code).

## License

[MIT](LICENSE)
