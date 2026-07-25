local log = require("codewars.logger")

---@class cw-ui.Utils
local utils = {}

function utils.buf_set_opts(bufnr, options)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    for opt, value in pairs(options) do
        local ok, err = pcall(vim.api.nvim_set_option_value, opt, value, { buf = bufnr })
        if not ok then
            log.error(err)
        end
    end
end

function utils.win_set_opts(winid, options)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

    for opt, value in pairs(options) do
        local ok, err =
            pcall(vim.api.nvim_set_option_value, opt, value, { win = winid, scope = "local" })
        if not ok then
            log.error(err)
        end
    end
end

function utils.win_set_winfixbuf(winid)
    if vim.fn.has("nvim-0.10.0") == 1 then
        utils.win_set_opts(winid, { winfixbuf = true })
    end
end

---@param winid number
---@param bufnr number
---@param force? boolean
function utils.win_set_buf(winid, bufnr, force)
    if vim.fn.has("nvim-0.10.0") == 1 then
        local ok, wfb = pcall(vim.api.nvim_get_option_value, "winfixbuf", { win = winid })

        if not ok or not wfb then
            vim.api.nvim_win_set_buf(winid, bufnr)
        elseif force then
            utils.win_set_opts(winid, { winfixbuf = false })
            vim.api.nvim_win_set_buf(winid, bufnr)
            utils.win_set_opts(winid, { winfixbuf = true })
        end
    else
        vim.api.nvim_win_set_buf(winid, bufnr)
    end
end

--- Jump to an already-open workspace's tab, if one matches.
---
--- Both workspaces open in their own tab and both must avoid opening a second
--- one for the same thing; only the state list and the identity check differ,
--- so the traversal lives here rather than once per workspace.
---@param list table[] workspaces to scan (e.g. _Cw_state.kumite)
---@param match fun(ws: table): boolean true for the workspace to focus
---@return boolean jumped
function utils.focus_existing_tab(list, match)
    for _, ws in ipairs(list or {}) do
        if ws.winid and vim.api.nvim_win_is_valid(ws.winid) and match(ws) then
            local ok, tabp = pcall(vim.api.nvim_win_get_tabpage, ws.winid)
            if ok then
                pcall(vim.api.nvim_set_current_tabpage, tabp)
                return true
            end
        end
    end
    return false
end

--- Coalesce repeated calls into one, `ms` after the last. Both workspaces
--- redraw their panel on TextChanged, which is far too often to run a full
--- dirty diff; each had its own copy of this flag-and-timer dance.
---@param owner table stores the pending flag (one debounce per owner+key)
---@param key string
---@param ms integer
---@param fn fun()
function utils.debounce(owner, key, ms, fn)
    local flag = "_debounce_" .. key
    if owner[flag] then
        return
    end
    owner[flag] = true
    vim.defer_fn(function()
        if owner[flag] then
            owner[flag] = nil
            fn()
        end
    end, ms)
end

--- Clear a pending debounce, so an immediate call supersedes it.
---@param owner table
---@param key string
function utils.debounce_cancel(owner, key)
    owner["_debounce_" .. key] = nil
end

--- Toggle `modifiable` across a set of buffers. The two workspaces gather
--- their buffer lists differently (five named panes vs a code buffer plus an
--- optional fixture split); only the loop is shared.
---@param bufnrs integer[]
---@param locked boolean
function utils.set_bufs_modifiable(bufnrs, locked)
    for _, bufnr in ipairs(bufnrs or {}) do
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            utils.buf_set_opts(bufnr, { modifiable = not locked })
        end
    end
end

--- Close a workspace buffer, or keep it when its stash never landed.
--- Deleting then would destroy the only remaining copy, so the buffer is
--- handed to the user instead: listed, normal, and renamed.
---@param bufnr integer
---@param rescue_label string? non-nil means keep it under this name
function utils.rescue_or_delete(bufnr, rescue_label)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
        return
    end
    if rescue_label then
        pcall(utils.buf_set_opts, bufnr, { buflisted = true, buftype = "" })
        pcall(vim.api.nvim_buf_set_name, bufnr, rescue_label)
    else
        vim.api.nvim_buf_delete(bufnr, { force = true, unload = false })
    end
end

function utils.buf_set_lines(bufnr, lines)
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
end

return utils
