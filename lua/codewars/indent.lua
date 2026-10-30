--- Indentation, per language, for the code this plugin puts in front of you.
---
--- Codewars' starter code is not consistently indented: the same language
--- arrives with two spaces on one kata and four on the next, while an editor
--- has one setting per filetype. Whichever the editor is set to, some katas
--- open with a starter that disagrees with it, and the first line typed
--- makes the file mixed.
---
--- The `indent` option names one style per language. The starter is
--- converted to it on its way into the file, and the buffer's indent options
--- are set to match. A language with no entry is never touched: the starter
--- stays as it came and the editor's own settings apply.
local M = {}

---@alias cw.IndentSpec integer|"tabs" spaces per level, or real tabs

M.MAX_WIDTH = 8

---@param spec any
---@return boolean
function M.valid_spec(spec)
    if spec == "tabs" then return true end
    return type(spec) == "number" and spec >= 1 and spec <= M.MAX_WIDTH and spec % 1 == 0
end

---@class cw.IndentStyle
---@field tabs boolean
---@field width integer characters of leading whitespace per level

--- The indentation `text` is written in, or nil when that cannot be read with
--- certainty: nothing is indented, tabs and spaces are mixed, some line is
--- indented by other than a whole number of levels (an aligned continuation,
--- say), or some line is more than one level deeper than the line before it.
--- nil means "leave it alone" -- a wrong guess here rewrites code.
---
--- The unit is the shallowest indentation present. Requiring every other
--- line to be a whole multiple of it is what makes the conversion safe: the
--- mapping from old depth to new is then strictly increasing, so two lines
--- at different depths can never land on the same one, in either direction.
---
--- Code opens one level at a time, which is what catches a unit that was
--- never a level: a comment box aligned one space in, over a body four
--- deep, would otherwise make each of those four spaces a level of its own.
---@param text string
---@return cw.IndentStyle?
function M.detect(text)
    local tabs, unit
    local depths = {}
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        -- Blank and whitespace-only lines say nothing about the style.
        local lead = line:match("^([ \t]*)%S")
        if lead and lead ~= "" then
            local has_tab = lead:find("\t", 1, true) ~= nil
            local has_space = lead:find(" ", 1, true) ~= nil
            if has_tab and has_space then return nil end
            if tabs == nil then
                tabs = has_tab
            elseif tabs ~= has_tab then
                return nil
            end
            if not unit or #lead < unit then unit = #lead end
        end
        if lead then depths[#depths + 1] = #lead end
    end
    if not unit then return nil end

    local previous = 0
    for _, depth in ipairs(depths) do
        if depth % unit ~= 0 or depth - previous > unit then return nil end
        previous = depth
    end
    return { tabs = tabs, width = unit }
end

--- `text` re-indented to `spec`, or `text` itself when its own style cannot
--- be read. Only leading whitespace changes; everything after it on a line,
--- line endings included, is carried over byte for byte. Lines inside a
--- multi-line string are indented lines like any other and move with the
--- rest.
---@param text string
---@param spec cw.IndentSpec
---@return string
function M.convert(text, spec)
    if not M.valid_spec(spec) then return text end
    local from = M.detect(text)
    if not from then return text end

    local level = spec == "tabs" and "\t" or string.rep(" ", spec)
    local out = {}
    for i, line in ipairs(vim.split(text, "\n", { plain = true })) do
        local lead, rest = line:match("^([ \t]+)(%S.*)$")
        out[i] = lead and (string.rep(level, #lead / from.width) .. rest) or line
    end
    return table.concat(out, "\n")
end

--- The buffer-local options that make an editor type in `spec`.
---@param spec cw.IndentSpec
---@return table<string, any>
function M.buf_options(spec)
    if spec == "tabs" then
        -- shiftwidth 0 follows tabstop, which is left alone: how wide a tab
        -- LOOKS is the reader's preference, not part of the style.
        return { expandtab = false, shiftwidth = 0, softtabstop = 0 }
    end
    return { expandtab = true, shiftwidth = spec, softtabstop = spec, tabstop = spec }
end

--- The style configured for `lang`, or nil when there is none -- in which
--- case nothing in this module touches the code or the buffer.
---@param lang string
---@return cw.IndentSpec?
function M.spec_for(lang)
    -- Several specs swap the config module for a bare table, so neither
    -- `user` nor `indent` can be assumed to be there.
    local user = require("codewars.config").user
    local cfg = type(user) == "table" and user.indent or nil
    local spec = type(cfg) == "table" and cfg[lang] or nil
    return M.valid_spec(spec) and spec or nil
end

--- A starter as it should be seeded for `lang`.
---@param lang string
---@param text string
---@return string
function M.starter(lang, text)
    local spec = M.spec_for(lang)
    if not spec then return text end
    return M.convert(text, spec)
end

--- Set a code buffer's indent options for `lang`. Call it after the buffer
--- has its filetype: the FileType event runs ftplugins, and whichever sets
--- these options last is the one that holds.
---@param bufnr integer?
---@param lang string
function M.setup_buffer(bufnr, lang)
    local spec = M.spec_for(lang)
    if not spec or not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
    for opt, value in pairs(M.buf_options(spec)) do
        vim.api.nvim_set_option_value(opt, value, { buf = bufnr })
    end
end

--- Check the `indent` option as the user wrote it. Run at setup(): a typo in
--- it has no symptom of its own, the option just does nothing for that
--- language.
---@param cfg any
---@param lang_slugs string[]
---@return string? err nil when the option is usable
function M.check_config(cfg, lang_slugs)
    if cfg == nil then return nil end
    local function shown(value)
        return (vim.inspect(value):gsub("%s+", " "))
    end
    if type(cfg) ~= "table" then
        return ("indent: expected a table keyed by language, got %s"):format(shown(cfg))
    end

    local known = {}
    for _, slug in ipairs(lang_slugs) do known[slug] = true end

    for slug, spec in pairs(cfg) do
        if not known[slug] then
            return ("indent.%s: unknown language"):format(tostring(slug))
        end
        if not M.valid_spec(spec) then
            return ('indent.%s: expected a number of spaces from 1 to %d, or "tabs"; got %s')
                :format(slug, M.MAX_WIDTH, shown(spec))
        end
    end
    return nil
end

return M
