local config = require("codewars.config")
local log = require("codewars.logger")

---@class cw.Utils
local utils = {}

---@param slug string
---@return cw.language?
function utils.get_lang(slug)
    return vim.tbl_filter(function(l)
        return l.slug == slug
    end, config.langs)[1]
end

--- Validate a user-supplied language argument, reporting unknown ones.
---@param lang_arg string
---@return cw.language? lang_info nil when unknown (error already logged)
function utils.resolve_lang_arg(lang_arg)
    local lang_info = utils.get_lang(lang_arg)
    if not lang_info then
        log.error(("Unknown language: %s"):format(lang_arg))
    end
    return lang_info
end

---@return cw.ui.Kata?
--- The kata whose tab is focused, or nil. Silent: for callers where "no kata
--- here" is an ordinary state rather than a mistake.
---@return cw.ui.Kata?, integer?
function utils.kata_in_tab()
    local tabp = vim.api.nvim_get_current_tabpage()

    local tab = vim.tbl_filter(function(t)
        return t.tabpage == tabp
    end, utils.kata_tabs())[1] or {}

    if tab.kata then
        return tab.kata, tabp
    end
end

function utils.curr_kata()
    local kata, tabp = utils.kata_in_tab()
    if kata then
        return kata, tabp
    end
    log.error("No current kata found")
end

--- The kumite workspace in the current tab, if any (no error when absent —
--- callers fall back to kata resolution).
---@return cw.ui.Kumite?
function utils.curr_kumite()
    local tabp = vim.api.nvim_get_current_tabpage()
    for _, ws in ipairs(_Cw_state.kumite or {}) do
        local ok, wtab = pcall(vim.api.nvim_win_get_tabpage, ws.winid)
        if ok and wtab == tabp then
            return ws
        end
    end
end

--- The kata authoring workspace in the current tab, if any. Same contract as
--- curr_kumite: silent when absent, so callers word their own message.
---@return cw.ui.KataEditor?
function utils.curr_kata_editor()
    local tabp = vim.api.nvim_get_current_tabpage()
    for _, ws in ipairs(_Cw_state.kata_editors or {}) do
        local ok, wtab = pcall(vim.api.nvim_win_get_tabpage, ws.winid)
        if ok and wtab == tabp then
            return ws
        end
    end
end

---@return { tabpage: integer, kata: cw.ui.Kata }[]
function utils.kata_tabs()
    local katas = {}

    for _, k in ipairs(_Cw_state.katas) do
        local tabp = utils.kata_tabp(k)
        if tabp then
            table.insert(katas, { tabpage = tabp, kata = k })
        end
    end

    return katas
end

---@param k cw.ui.Kata
---@return integer?
function utils.kata_tabp(k)
    local ok, tabp = pcall(vim.api.nvim_win_get_tabpage, k.winid)
    if ok then
        return tabp
    end
end

---@param title_slug string
---@param lang cw.lang
function utils.detect_duplicate_kata(title_slug, lang)
    local tabs = utils.kata_tabs()

    for _, k in ipairs(tabs) do
        if title_slug == k.kata.slug and lang == k.kata.lang then
            return k.tabpage
        end
    end
end

--- Parse a codewars URL or slug into a slug
---@param input string
---@return string
function utils.parse_slug(input)
    local slug = input:match("codewars%.com/kata/([^/]+)")
    if slug then
        return slug
    end
    return input
end

function utils.auth_guard()
    local cookie = require("codewars.cache.cookie")
    if not cookie.get() then
        error("Not signed in. Use :CW cookie to set your browser cookies.", 0)
    end
end

---@param event cw.hook
function utils.exec_hooks(event, ...)
    local fns = config.user.hooks[event]
    if not fns then
        return
    end

    if type(fns) == "function" then
        fns = { fns }
    end

    for i, fn in ipairs(fns) do
        local ok, msg = pcall(fn, ...)
        if not ok then
            log.error(("bad hook #%d in `%s` event: %s"):format(i, event, msg))
        end
    end
end

return utils
