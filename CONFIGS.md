# Configuration

All settings are optional. Pass them to `require("codewars").setup({})`.

Username and language are auto-detected from Codewars when signed in.

## Quick Start

```lua
require("codewars").setup({})
```

That's it. Everything below is optional.

## General

| Option | Type | Default | Description |
|---|---|---|---|
| `arg` | `string` | `"codewars.nvim"` | Standalone mode argument. Launch with `nvim codewars.nvim` to open the dashboard. |
| `lang` | `string` | `"python"` | Default language for training. Auto-detected from Codewars if empty. Use `:CW lang default <lang>` to persist across restarts. |
| `logging` | `boolean` | `true` | Show notification messages. |
| `debug` | `boolean` | `false` | Enable debug logging (verbose). |

## Storage

Where solution files and cache data are stored.

```lua
storage = {
    home = vim.fn.stdpath("data") .. "/codewars",   -- solution files
    cache = vim.fn.stdpath("cache") .. "/codewars",  -- session cache, cookies, problem list
},
```

| Option | Default | Description |
|---|---|---|
| `storage.home` | `~/.local/share/nvim/codewars` | Directory for kata solution files. |
| `storage.cache` | `~/.cache/nvim/codewars` | Directory for cookies, session cache, problem list cache, persisted language. |

## Templates

Starter code for solution buffers, per language. Optional — with no `templates`
table you get exactly what Codewars seeds, unchanged.

```lua
templates = {
    solution = {
        -- {{starter}} is replaced with the code Codewars seeds for the kata:
        -- the function signature it grades against.
        python = [[
from collections import Counter, defaultdict, deque
from functools import cache
import math

{{starter}}
]],
    },
},
```

| Option | Type | Default | Description |
|---|---|---|---|
| `templates.solution` | `table<string, string\|function>` | `{}` | Keyed by language slug. Each value is the template text, or a function returning it. |

### Wrapping vs replacing

A template containing `{{starter}}` **wraps** Codewars' starter code. A template
without it **replaces** the buffer entirely — you are then responsible for
writing the graded signature yourself, and the plugin warns once per language
per session so it cannot happen silently.

### Function form

Use a function when the template depends on the kata:

```lua
templates = {
    solution = {
        rust = function(ctx)
            return ("// %s\n\n%s"):format(ctx.name or ctx.slug, ctx.starter)
        end,
    },
},
```

`ctx` carries `lang`, `ext`, `slug`, `name`, `rank`, `tags`, and `starter`.
Fields other than `lang` and `starter` may be `nil` — a brand-new kumite has no
kata title or rank. Return `nil` or `""` to decline and fall back to Codewars'
starter, which makes per-kata opt-outs easy:

```lua
python = function(ctx)
    if ctx.rank and ctx.rank > -5 then
        return nil -- leave hard kata alone
    end
    return "import math\n\n{{starter}}"
end,
```

To keep templates as real source files with working highlighting and LSP, read
them from disk:

```lua
python = function(ctx)
    local lines = vim.fn.readfile(vim.fn.expand("~/.config/nvim/codewars/solution.py"))
    return (table.concat(lines, "\n"):gsub("{{starter}}", function()
        return ctx.starter
    end))
end,
```

A template that errors is reported and skipped, never fatal — a broken template
cannot stop a kata from opening.

### Turning templates off

```
:CW template          -- current state, and whether this language has one
:CW template off      -- stop applying templates, and unwrap the open kata
:CW template on       -- resume, and wrap the open kata's code
```

The switch is global and persisted, so it survives a restart. Alongside it, the
kata you have open is rewritten to match — flipping the switch and then looking
at a buffer that still has the old shape is the confusing half.

That rewrite is byte-exact or it refuses. Once you have edited the template's
own lines, nothing in the buffer reliably says which came from the template, so
rather than guess and delete your code it tells you it could not, and leaves the
buffer alone. Either rewrite is a single undo entry, so `u` puts it back.

### Where templates apply

`:CW train`, `:CW reset`, switching a kata's language, and new kumites
(`:CW kumite new`, and adding a language in the kata editor). Existing solution
files on disk are never rewritten, so adding a template does not disturb work in
progress; use `:CW reset` to pull it into a kata you already started. When you
open a kata whose file already exists and a template is configured for that
language, the plugin says so, so a skipped template never looks like a broken
one.

## Cache

```lua
cache = {
    update_interval = 60 * 60 * 24 * 7,  -- 7 days
},
```

| Option | Default | Description |
|---|---|---|
| `cache.update_interval` | `604800` (7 days) | How long before the problem list cache is considered stale (seconds). Set to `0` to always re-fetch. |

## Console (Result Popup)

The floating popup that shows test/attempt results.

```lua
console = {
    open_on_runcode = true,
    size = { width = "60%", height = "60%" },
},
```

| Option | Default | Description |
|---|---|---|
| `console.open_on_runcode` | `true` | Automatically open the console when running `:CW test` or `:CW attempt`. |
| `console.size.width` | `"60%"` | Console popup width. Accepts percentage string or pixel number. |
| `console.size.height` | `"60%"` | Console popup height. |

## Test Cases Split

The editable split below the code editor showing test fixtures.

```lua
testcase = {
    open_on_enter = true,
    position = "bottom",
    size = "30%",
},
```

| Option | Default | Description |
|---|---|---|
| `testcase.open_on_enter` | `true` | Show the test cases split when opening a kata. |
| `testcase.position` | `"bottom"` | Where to place the split: `"top"` or `"bottom"`. |
| `testcase.size` | `"30%"` | Height of the split. Accepts percentage string or pixel number. |

## Description Split

The markdown-rendered kata description panel.

```lua
description = {
    position = "left",
    width = "40%",
},
```

| Option | Default | Description |
|---|---|---|
| `description.position` | `"left"` | Where to place the description: `"left"`, `"right"`, `"top"`, or `"bottom"`. |
| `description.width` | `"40%"` | Width (or height if top/bottom) of the description split. |

## Keybindings

```lua
keys = {
    toggle = { "q" },
},
```

| Option | Default | Description |
|---|---|---|
| `keys.toggle` | `{ "q" }` | Key(s) to close/toggle popups and splits. Accepts a string or list of strings. |

## Lifecycle Hooks

Callbacks that run at specific plugin events.

```lua
hooks = {
    enter = {},
    kata_enter = {},
    leave = {},
},
```

| Option | Type | Description |
|---|---|---|
| `hooks.enter` | `fun()[]` | Called when the plugin starts (dashboard opens). |
| `hooks.kata_enter` | `fun(kata)[]` | Called when a kata is opened. Receives the kata object. |
| `hooks.leave` | `fun()[]` | Called when the plugin exits. |

Example:

```lua
hooks = {
    kata_enter = {
        function(kata)
            print("Opened kata: " .. kata.slug)
        end,
    },
},
```

## Theme

Override highlight group colors. See `lua/codewars/theme/init.lua` for the full list of groups.

```lua
theme = {
    codewars_header = { fg = "#ff0000" },
    codewars_rank_purple = { fg = "#9b59b6", bold = true },
},
```

## Icons

Override Nerd Font icons. See `lua/codewars/icons.lua` for all defaults.

```lua
icons = {
    test_passed = "✓",
    test_failed = "✗",
    lang_python = "",
},
```

**Available keys:**

- **Result:** `all_passed`, `tests_failed`, `test_passed`, `test_failed`
- **Picker:** `completed`, `rank`
- **Menu:** `katas`, `stats`, `cookie`, `cache`, `exit`, `search`, `list`, `random`, `back`, `update`, `signin`, `signout`, `expand`
- **Languages:** `lang_<slug>` (e.g. `lang_python`, `lang_go`, `lang_rust`)

## Full Example

```lua
require("codewars").setup({
    lang = "python",
    console = {
        size = { width = "80%", height = "70%" },
    },
    description = {
        position = "left",
        width = "35%",
    },
    theme = {
        codewars_header = { fg = "#e74c3c" },
    },
    hooks = {
        kata_enter = {
            function(kata)
                vim.notify("Training: " .. (kata.name or kata.slug))
            end,
        },
    },
})
```
