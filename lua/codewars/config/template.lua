---@alias cw.lang
---| "python"
---| "javascript"
---| "typescript"
---| "ruby"
---| "java"
---| "cpp"
---| "c"
---| "csharp"
---| "go"
---| "rust"
---| "haskell"
---| "clojure"
---| "elixir"
---| "swift"
---| "kotlin"
---| "scala"
---| "php"
---| "shell"
---| "lua"
---| "coffeescript"
---| "sql"
---| "dart"
---| "r"
---| "nim"
---| "crystal"
---| "julia"
---| "racket"
---| "ocaml"
---| "fsharp"
---| "erlang"
---| "fortran"
---| "nasm"

---@alias cw.hook
---| "enter"
---| "kata_enter"
---| "leave"

---@alias cw.size
---| string
---| number
---| { width: string | number, height: string | number }

---@alias cw.position "top" | "right" | "bottom" | "left"

---@alias cw.direction "col" | "row"

---@alias cw.storage table<"cache"|"home", string>

---@alias cw.picker { provider?: "telescope" }

---@class cw.UserConfig
local M = {
    ---@type string
    arg = "codewars.nvim",

    ---@type cw.lang
    lang = "python",

    ---@type string
    --- Leave empty to auto-detect from Codewars when signed in
    username = "",

    ---@type cw.storage
    storage = {
        home = vim.fn.stdpath("data") .. "/codewars",
        cache = vim.fn.stdpath("cache") .. "/codewars",
    },

    ---@type boolean
    logging = true,

    ---@type boolean
    debug = false,

    cache = {
        update_interval = 60 * 60 * 24 * 7, ---@type integer 7 days
    },

    console = {
        open_on_runcode = true, ---@type boolean
        size = { ---@type cw.size
            width = "60%",
            height = "60%",
        },
    },

    testcase = {
        open_on_enter = true, ---@type boolean
        position = "bottom", ---@type "top" | "bottom"
        size = "30%", ---@type cw.size
    },

    description = {
        position = "left", ---@type cw.position

        width = "40%", ---@type cw.size
    },

    ---@type cw.picker
    picker = { provider = nil },

    hooks = {
        ---@type fun()[]
        ["enter"] = {},

        ---@type fun(kata: cw.ui.Kata)[]
        ["kata_enter"] = {},

        ---@type fun()[]
        ["leave"] = {},
    },

    keys = {
        toggle = { "q" }, ---@type string|string[]
    },

    ---@type table
    --- Override default highlight colors. Example:
    --- theme = { codewars_header = { fg = "#ff0000" } }
    theme = {},

    ---@type table
    --- Override default icons. Example:
    --- icons = { test_passed = "✓", test_failed = "✗" }
    icons = {},
}

return M
