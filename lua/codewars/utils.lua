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

---@return cw.ui.Kata?
function utils.curr_kata()
    local tabp = vim.api.nvim_get_current_tabpage()
    local tabs = utils.kata_tabs()

    local tab = vim.tbl_filter(function(t)
        return t.tabpage == tabp
    end, tabs)[1] or {}

    if tab.kata then
        return tab.kata, tabp
    else
        log.error("No current kata found")
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
