local theme = {}

local highlights = {
    codewars_ok = { fg = "#2cbe4e", bold = true },
    codewars_error = { fg = "#f44747", bold = true },
    codewars_info = { fg = "#61afef", bold = true },
    codewars_warning = { fg = "#e5c07b", bold = true },
    codewars_normal = { fg = "#abb2bf" },
    codewars_ref = { fg = "#5c6370", italic = true },
    codewars_header = { fg = "#b1361e", bold = true }, -- Codewars red
    codewars_icon = { fg = "#DA70D6" },
    codewars_shortcut = { fg = "#40E0D0" },
    codewars_breadcrumb = { fg = "#5c6370" },
    codewars_rank_white = { fg = "#e6e6e6" },
    codewars_rank_yellow = { fg = "#ecb613" },
    codewars_rank_blue = { fg = "#3c7ebb" },
    codewars_rank_purple = { fg = "#866cc7" },
    codewars_completed = { fg = "#2cbe4e" },

    -- Success rate colors
    codewars_rate_white = { fg = "#e6e6e6" },
    codewars_rate_yellow = { fg = "#ecb613" },
    codewars_rate_orange = { fg = "#e5945e" },
    codewars_rate_green = { fg = "#2cbe4e" },
    codewars_rate_blue = { fg = "#3c7ebb" },
    codewars_rate_red = { fg = "#f44747" },
    codewars_rate_pink = { fg = "#e06c9f" },
    codewars_rate_purple = { fg = "#866cc7" },
    codewars_rate_gray = { fg = "#5c6370" },
    codewars_rate_brown = { fg = "#8b6914" },
    codewars_rate_black = { fg = "#333333" },

    -- Language icon colors
    codewars_lang_python = { fg = "#3776AB" },
    codewars_lang_javascript = { fg = "#F7DF1E" },
    codewars_lang_typescript = { fg = "#3178C6" },
    codewars_lang_ruby = { fg = "#CC342D" },
    codewars_lang_java = { fg = "#ED8B00" },
    codewars_lang_cpp = { fg = "#00599C" },
    codewars_lang_c = { fg = "#A8B9CC" },
    codewars_lang_csharp = { fg = "#512BD4" },
    codewars_lang_go = { fg = "#00ADD8" },
    codewars_lang_rust = { fg = "#DEA584" },
    codewars_lang_haskell = { fg = "#5D4F85" },
    codewars_lang_clojure = { fg = "#5881D8" },
    codewars_lang_elixir = { fg = "#4B275F" },
    codewars_lang_swift = { fg = "#F05138" },
    codewars_lang_kotlin = { fg = "#7F52FF" },
    codewars_lang_scala = { fg = "#DC322F" },
    codewars_lang_php = { fg = "#777BB4" },
    codewars_lang_shell = { fg = "#4EAA25" },
    codewars_lang_lua = { fg = "#2C2D72" },
    codewars_lang_coffeescript = { fg = "#2F2625" },
    codewars_lang_sql = { fg = "#4169E1" },
    codewars_lang_dart = { fg = "#0175C2" },
    codewars_lang_r = { fg = "#276DC3" },
    codewars_lang_nim = { fg = "#FFE953" },
    codewars_lang_crystal = { fg = "#000000" },
    codewars_lang_julia = { fg = "#9558B2" },
    codewars_lang_racket = { fg = "#9F1D20" },
    codewars_lang_ocaml = { fg = "#EC6813" },
    codewars_lang_fsharp = { fg = "#378BBA" },
    codewars_lang_erlang = { fg = "#A90533" },
    codewars_lang_fortran = { fg = "#734F96" },
    codewars_lang_nasm = { fg = "#105060" },
    codewars_lang_cobol = { fg = "#3B5998" },      -- IBM blue
    codewars_lang_d = { fg = "#B03931" },           -- D lang red
    codewars_lang_prolog = { fg = "#E4552D" },      -- SWI-Prolog orange
    codewars_lang_factor = { fg = "#636746" },      -- Factor olive
    codewars_lang_groovy = { fg = "#4298B8" },      -- Groovy blue
    codewars_lang_perl = { fg = "#0298C3" },        -- Perl cyan
    codewars_lang_lambdacalc = { fg = "#DAA520" },  -- lambda gold
    codewars_lang_powershell = { fg = "#012456" },  -- PowerShell dark blue
    codewars_lang_elm = { fg = "#60B5CC" },         -- Elm blue
    codewars_lang_reason = { fg = "#DD4B39" },      -- ReasonML red
    codewars_lang_bf = { fg = "#7A7A7A" },          -- Brainfuck gray
    codewars_lang_pascal = { fg = "#E3F171" },      -- Pascal yellow-green
    codewars_lang_objc = { fg = "#438EFF" },        -- Objective-C blue
    codewars_lang_haxe = { fg = "#EA8220" },        -- Haxe orange
    codewars_lang_riscv = { fg = "#283272" },       -- RISC-V navy
    codewars_lang_coq = { fg = "#D0B68C" },         -- Coq tan
    codewars_lang_forth = { fg = "#341708" },       -- Forth brown
    codewars_lang_raku = { fg = "#0098D8" },        -- Raku blue (Perl 6)
    codewars_lang_purescript = { fg = "#1D222D" },  -- PureScript dark
    codewars_lang_agda = { fg = "#315665" },        -- Agda teal
    codewars_lang_lean = { fg = "#2E3A4E" },        -- Lean dark blue
    codewars_lang_commonlisp = { fg = "#3FB68B" },  -- Common Lisp green
    codewars_lang_idris = { fg = "#B30000" },       -- Idris dark red
    codewars_lang_solidity = { fg = "#363636" },    -- Solidity dark gray
    codewars_lang_vb = { fg = "#945DB7" },          -- Visual Basic purple
    codewars_lang_cfml = { fg = "#ED2CD6" },        -- CFML magenta
}

function theme.setup()
    local config = require("codewars.config")
    local overrides = config.user.theme or {}

    for name, val in pairs(highlights) do
        local hl = vim.tbl_deep_extend("force", val, overrides[name] or {})
        vim.api.nvim_set_hl(0, name, hl)
    end
end

---@param rank integer kyu rank (negative = kyu, positive = dan)
---@return string highlight group
function theme.rank_hl(rank)
    if rank >= -8 and rank <= -7 then
        return "codewars_rank_white"
    elseif rank >= -6 and rank <= -5 then
        return "codewars_rank_yellow"
    elseif rank >= -4 and rank <= -3 then
        return "codewars_rank_blue"
    else
        return "codewars_rank_purple"
    end
end

---@param rank integer
---@return string display string like "5 kyu" or "1 dan"
function theme.rank_str(rank)
    if rank < 0 then
        return math.abs(rank) .. " kyu"
    else
        return rank .. " dan"
    end
end

return theme
