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

function utils.buf_set_lines(bufnr, lines)
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
end

return utils
