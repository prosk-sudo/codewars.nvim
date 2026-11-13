local theme = {}

-- Every group derives from a standard group the colorscheme defines. A spec
-- with only `link` becomes a real link; extra style keys (bold, italic, ...)
-- cannot ride on a link, so those take the target's fg plus the style.
local highlights = {
    codewars_ok = { link = "DiagnosticOk", bold = true },
    codewars_error = { link = "DiagnosticError", bold = true },
    codewars_info = { link = "DiagnosticInfo", bold = true },
    codewars_warning = { link = "DiagnosticWarn", bold = true },
    codewars_normal = { link = "Normal" },
    codewars_ref = { link = "Comment", italic = true },
    codewars_header = { link = "Title", bold = true },
    codewars_icon = { link = "Special" },
    codewars_shortcut = { link = "Function" },
    codewars_breadcrumb = { link = "Comment" },
    -- Hint box (keybinding legends)
    codewars_hint = { link = "DiagnosticHint" },
    codewars_hint_border = { link = "DiagnosticHint" },
    codewars_hint_key = { link = "DiagnosticHint", bold = true },
    codewars_rank_white = { link = "Normal" },
    codewars_rank_yellow = { link = "DiagnosticWarn" },
    codewars_rank_blue = { link = "DiagnosticInfo" },
    codewars_rank_purple = { link = "Statement" },
    codewars_completed = { link = "DiagnosticOk" },

    -- Solution comment thread (rendered from the site's markdown-lite)
    codewars_comment_author = { link = "Normal", bold = true },
    codewars_comment_guide = { link = "Comment" },
    codewars_comment_bold = { bold = true },
    codewars_comment_italic = { italic = true },
    codewars_comment_code = { link = "String" },
    codewars_comment_link = { link = "Underlined" },

    -- Success rate colors
    codewars_rate_white = { link = "Normal" },
    codewars_rate_yellow = { link = "DiagnosticWarn" },
    codewars_rate_orange = { link = "Number" },
    codewars_rate_green = { link = "DiagnosticOk" },
    codewars_rate_blue = { link = "DiagnosticInfo" },
    codewars_rate_red = { link = "DiagnosticError" },
    codewars_rate_pink = { link = "Special" },
    codewars_rate_purple = { link = "Statement" },
    codewars_rate_gray = { link = "Comment" },
    codewars_rate_brown = { link = "Type" },
    codewars_rate_black = { link = "NonText" },

    -- Language icons: one theme color, each still overridable on its own
    codewars_lang = { link = "Special" },
    codewars_lang_python = { link = "codewars_lang" },
    codewars_lang_javascript = { link = "codewars_lang" },
    codewars_lang_typescript = { link = "codewars_lang" },
    codewars_lang_ruby = { link = "codewars_lang" },
    codewars_lang_java = { link = "codewars_lang" },
    codewars_lang_cpp = { link = "codewars_lang" },
    codewars_lang_c = { link = "codewars_lang" },
    codewars_lang_csharp = { link = "codewars_lang" },
    codewars_lang_go = { link = "codewars_lang" },
    codewars_lang_rust = { link = "codewars_lang" },
    codewars_lang_haskell = { link = "codewars_lang" },
    codewars_lang_clojure = { link = "codewars_lang" },
    codewars_lang_elixir = { link = "codewars_lang" },
    codewars_lang_swift = { link = "codewars_lang" },
    codewars_lang_kotlin = { link = "codewars_lang" },
    codewars_lang_scala = { link = "codewars_lang" },
    codewars_lang_php = { link = "codewars_lang" },
    codewars_lang_shell = { link = "codewars_lang" },
    codewars_lang_lua = { link = "codewars_lang" },
    codewars_lang_coffeescript = { link = "codewars_lang" },
    codewars_lang_sql = { link = "codewars_lang" },
    codewars_lang_dart = { link = "codewars_lang" },
    codewars_lang_r = { link = "codewars_lang" },
    codewars_lang_nim = { link = "codewars_lang" },
    codewars_lang_crystal = { link = "codewars_lang" },
    codewars_lang_julia = { link = "codewars_lang" },
    codewars_lang_racket = { link = "codewars_lang" },
    codewars_lang_ocaml = { link = "codewars_lang" },
    codewars_lang_fsharp = { link = "codewars_lang" },
    codewars_lang_erlang = { link = "codewars_lang" },
    codewars_lang_fortran = { link = "codewars_lang" },
    codewars_lang_nasm = { link = "codewars_lang" },
    codewars_lang_cobol = { link = "codewars_lang" },
    codewars_lang_d = { link = "codewars_lang" },
    codewars_lang_prolog = { link = "codewars_lang" },
    codewars_lang_factor = { link = "codewars_lang" },
    codewars_lang_groovy = { link = "codewars_lang" },
    codewars_lang_perl = { link = "codewars_lang" },
    codewars_lang_lambdacalc = { link = "codewars_lang" },
    codewars_lang_powershell = { link = "codewars_lang" },
    codewars_lang_elm = { link = "codewars_lang" },
    codewars_lang_reason = { link = "codewars_lang" },
    codewars_lang_bf = { link = "codewars_lang" },
    codewars_lang_pascal = { link = "codewars_lang" },
    codewars_lang_objc = { link = "codewars_lang" },
    codewars_lang_haxe = { link = "codewars_lang" },
    codewars_lang_riscv = { link = "codewars_lang" },
    codewars_lang_coq = { link = "codewars_lang" },
    codewars_lang_forth = { link = "codewars_lang" },
    codewars_lang_raku = { link = "codewars_lang" },
    codewars_lang_purescript = { link = "codewars_lang" },
    codewars_lang_agda = { link = "codewars_lang" },
    codewars_lang_lean = { link = "codewars_lang" },
    codewars_lang_commonlisp = { link = "codewars_lang" },
    codewars_lang_idris = { link = "codewars_lang" },
    codewars_lang_solidity = { link = "codewars_lang" },
    codewars_lang_vb = { link = "codewars_lang" },
    codewars_lang_cfml = { link = "codewars_lang" },
}

--- Test seam: the built-in specs.
theme._specs = highlights

--- Target's fg (never bg, so floats keep their own background) plus `extra`.
---@param target string
---@param extra table
---@return table
local function resolve(target, extra)
    local base = vim.api.nvim_get_hl(0, { name = target, link = false })
    return vim.tbl_extend("force", { fg = base.fg, ctermfg = base.ctermfg }, extra)
end

---@param spec table
---@param override table?
---@return table
local function build(spec, override)
    if override and override.link then return override end
    local extra = {}
    for k, v in pairs(spec) do
        if k ~= "link" then extra[k] = v end
    end
    if override then extra = vim.tbl_extend("force", extra, override) end
    if not spec.link then return extra end
    if next(extra) == nil then return { link = spec.link } end
    return resolve(spec.link, extra)
end

local function apply()
    local config = require("codewars.config")
    local overrides = (config.user and config.user.theme) or {}
    -- codewars_lang first: lang_* link to it, and a resolved group reads it.
    vim.api.nvim_set_hl(0, "codewars_lang", build(highlights.codewars_lang, overrides.codewars_lang))
    for name, spec in pairs(highlights) do
        if name ~= "codewars_lang" then
            vim.api.nvim_set_hl(0, name, build(spec, overrides[name]))
        end
    end
end

function theme.setup()
    apply()
    -- A colorscheme switch clears every group; re-derive from the new one.
    local group = vim.api.nvim_create_augroup("codewars_theme", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = apply })
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
