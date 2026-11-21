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
    -- Light-blue hint box (keybinding legends)
    codewars_hint = { fg = "#7dcfff" },
    codewars_hint_border = { fg = "#7dcfff" },
    codewars_hint_key = { fg = "#7dcfff", bold = true },
    codewars_rank_white = { fg = "#e6e6e6" },
    codewars_rank_yellow = { fg = "#ecb613" },
    codewars_rank_blue = { fg = "#3c7ebb" },
    codewars_rank_purple = { fg = "#866cc7" },
    codewars_completed = { fg = "#2cbe4e" },

    -- Solution comment thread (rendered from the site's markdown-lite)
    codewars_comment_author = { fg = "#e6e6e6", bold = true },
    codewars_comment_guide = { fg = "#5c6370" },
    codewars_comment_bold = { bold = true },
    codewars_comment_italic = { italic = true },
    codewars_comment_code = { fg = "#98c379" },
    codewars_comment_link = { fg = "#61afef", underline = true },

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

local colors

--- The definition to set for one codewars group.
--- A `link` override replaces the default spec instead of merging into it:
--- merged, `{ fg = "#b1361e", bold = true, link = "Comment" }` is both a link
--- and a color. Any other override merges over the default as before.
--- A link cannot carry attributes, so `{ link = "X", bold = true }` becomes X's
--- foreground with the style keys on top (an explicit fg wins). Only the
--- foreground is taken, never the background, so a float keeps its own.
---@param name string a key of `highlights`
---@param overrides table the user's `theme`
---@param seen table<string, true> the groups on the chain of links that led here
---@return table
local function definition(name, overrides, seen)
    local spec, override = highlights[name], overrides[name]
    if not override then
        return spec
    end
    if not override.link then
        return vim.tbl_deep_extend("force", spec, override)
    end

    local style = {}
    for key, value in pairs(override) do
        if key ~= "link" then
            style[key] = value
        end
    end
    if next(style) == nil then
        return { link = override.link }
    end
    local base = colors(override.link, overrides, seen)
    return vim.tbl_extend("force", { fg = base.fg, ctermfg = base.ctermfg }, style)
end

--- The foreground (fg, ctermfg) that `target` has once apply() has run.
--- The chain of links is followed one step at a time and Neovim is never asked
--- to collapse it: apply() visits the groups in no particular order, and
--- straight after a `:colorscheme` ours hold nothing, so what Neovim would
--- resolve through a codewars group is not what that group will hold. Every
--- step lands on one of two things:
---   * a codewars group: worked out from its default and the user's override;
---   * any other group: read with `link = true`. A group that links gives
---     `{ link = "X" }` and the walk goes on with X (a group that has both a
---     link and an fg of its own follows the link, as Neovim does); a group
---     that does not link gives its own fg and ctermfg. These are the
---     colorscheme as it is now; apply() runs again after every `:colorscheme`.
--- A link that leads back to a group already on the chain (a -> b -> a, a -> a,
--- or one that mixes codewars groups with others) has no color to give. Every
--- codewars group in such a cycle keeps only its own style keys, whichever of
--- them is being applied.
--- Neovim matches group names without regard to case, so "CODEWARS_HEADER"
--- names the same group as "codewars_header". Every key of `highlights` is
--- lowercase, so the lowered target is the key for the lookup and for the
--- cycle check, whichever group it names. (A link-only override still goes to
--- Neovim as the user wrote it, and Neovim resolves it.)
---@param target string
---@param overrides table the user's `theme`
---@param seen table<string, true> the groups on the chain of links that led here
---@return table
colors = function(target, overrides, seen)
    -- tostring: a `link` that is not a string is Neovim's to reject, below
    local key = tostring(target):lower()
    if seen[key] then
        return {}
    end
    local chain = vim.tbl_extend("force", seen, { [key] = true })

    if highlights[key] then
        local def = definition(key, overrides, chain)
        if def.link then
            return colors(def.link, overrides, chain)
        end
        return { fg = def.fg, ctermfg = def.ctermfg }
    end

    local group = vim.api.nvim_get_hl(0, { name = target, link = true })
    if group.link then
        return colors(group.link, overrides, chain)
    end
    return { fg = group.fg, ctermfg = group.ctermfg }
end

local function apply()
    local config = require("codewars.config")
    local overrides = config.user.theme or {}

    for name in pairs(highlights) do
        vim.api.nvim_set_hl(0, name, definition(name, overrides, { [name] = true }))
    end
end

function theme.setup()
    apply()

    -- `:colorscheme` clears every highlight group, ours included. The group is
    -- created with clear = true so a second setup() replaces this autocmd
    -- instead of stacking another copy.
    local group = vim.api.nvim_create_augroup("codewars_theme", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        desc = "codewars.nvim: re-apply highlights after a colorscheme change",
        callback = function()
            apply()
        end,
    })
end

--- Unranked (beta) kata carry no numeric rank — JSON null upstream, so
--- the value may be nil or (off the luanil-disciplined paths) vim.NIL.
---@param rank any
---@return boolean
function theme.is_unranked(rank)
    return type(rank) ~= "number"
end

---@param rank integer|any kyu rank (negative = kyu, positive = dan); tolerates vim.NIL/nil (beta kata are unranked)
---@return string highlight group
function theme.rank_hl(rank)
    if theme.is_unranked(rank) then
        return "codewars_rank_purple"
    end
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

---@param rank integer|any tolerates vim.NIL/nil (beta kata are unranked)
---@return string display string like "5 kyu", "1 dan", or "beta"
function theme.rank_str(rank)
    if theme.is_unranked(rank) then
        return "beta"
    end
    if rank < 0 then
        return math.abs(rank) .. " kyu"
    else
        return rank .. " dan"
    end
end

return theme
