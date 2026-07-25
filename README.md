# codewars.nvim

Solve [Codewars](https://www.codewars.com) katas from within Neovim.

![codewars.nvim](mainmenu.png)

## What it does

- **Train** — open any kata by slug or URL, write your solution with the
  description and test cases beside it, then `test` / `attempt` / `submit`.
- **Find work** — browse and filter all kata, see your completed ones, or let
  Codewars' trainer pick with Choose Today's Focus.
- **Leaderboards** — top-500 boards for Overall, Completed Kata, Authored Kata
  & Translations, and Ranks.
- **Freestyle Sparring** — browse kumite, fork one into an editable copy, run
  it against its fixture, and save or publish it back.
- **Author kata** — turn a kumite into a kata and finish it without leaving
  Neovim: solution, initial solution, tests, example tests, description,
  metadata, language and runtime, then publish.

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

**Solve a kata**

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

**Find something to solve**

```
:CW focus                " let the trainer pick — Choose Today's Focus
:CW list                 " browse all kata, with filters
:CW completed            " kata you have already finished
:CW leaderboard          " top 500 boards (also in the menu under l)
```

**Freestyle Sparring (kumite)**

```
:CW kumite               " browse kumite (menu m)
:CW kumite new [lang]    " start a fresh one
:CW kumite fork          " edit a local copy of someone else's
:CW test                 " run it against its fixture
:CW kumite save          " save it to codewars.com as a draft
:CW kumite publish       " publish it publicly (tests must pass)
:CW kumite unpublish     " hide it again (reversible)
:CW kumite convert       " turn it into a kata you can author
```

**Author a kata**

A kata starts life as a kumite: `:CW kumite convert` creates the draft and
reports its id.

```
:CW kata open <id|url>   " open it in the five-pane editor
```

The editor puts each field in its own buffer, switched with `g1`…`g5`:
Complete Solution, Initial Solution, Test Cases, Example Test Cases, and
Description. Edits in a hidden pane are never lost.

```
:CW kata pane [name]     " show one field by name (answer|setup|fixture|example|description)
:CW kata meta            " name, discipline, estimated rank, tags, contributors
:CW kata lang            " switch language, or add one to this kata
:CW kata version         " pick the runtime (e.g. Python 3.8 / 3.10 / 3.11)
:CW kata validate        " run your solution against the kata's own test cases
:CW kata save            " save the draft
:CW kata publish         " publish it (confirms first; Codewars re-runs your tests)
:CW kata unpublish       " take it back to a draft
:CW kata delete          " delete it for good (confirms first)
```

If Codewars rejects a save, publish, or convert because the name is taken, the
plugin offers a rename and retries.

### Health check

```
:CW doctor
```

Reports Neovim version, dependencies, auth state, and cache status. It also
runs the HTML parsers against committed fixtures — Codewars has no public API
for most of this data, so that check turns a silent scraping break into a
visible diagnostic.

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
