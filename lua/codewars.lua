local config = require("codewars.config")

---@class cw.Codewars
local codewars = {}

---@private
local function buf_is_empty(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
    return not (#lines > 1 or (#lines == 1 and lines[1]:len() > 0))
end

---@param on_vimenter boolean
---@return boolean skip, boolean? standalone
function codewars.should_skip(on_vimenter)
    if on_vimenter then
        if vim.fn.argc(-1) ~= 1 then
            return true
        end

        local usr_arg, arg = config.user.arg, vim.fn.argv(0, -1)
        if usr_arg ~= arg then
            return true
        end

        if not buf_is_empty(0) then
            return true
        end

        return false, true
    else
        local listed_bufs = vim.tbl_filter(function(info)
            return info.listed == 1
        end, vim.fn.getbufinfo())

        if #listed_bufs == 0 then
            return false, true
        elseif vim.fn.argc(-1) == 0 and #listed_bufs == 1 then
            local buf = listed_bufs[1]

            if vim.api.nvim_get_current_buf() ~= buf.bufnr then
                return true
            end

            vim.schedule(function()
                if buf.changed == 1 then
                    vim.api.nvim_buf_delete(buf.bufnr, { force = true })
                end
            end)

            return false, true
        else
            return true
        end
    end
end

--- Open the dashboard menu in the current window
function codewars.show_menu()
    local utils = require("codewars.utils")
    utils.exec_hooks("enter")

    local Menu = require("codewars-ui.renderer.menu")
    _Cw_state.menu = Menu:init()
    _Cw_state.menu:mount()
end

function codewars.stop()
    local utils = require("codewars.utils")
    utils.exec_hooks("leave")

    for _, k in ipairs(_Cw_state.katas) do
        k:unmount()
    end

    if _Cw_state.menu then
        pcall(function()
            vim.api.nvim_buf_delete(_Cw_state.menu.bufnr, { force = true })
        end)
    end

    vim.cmd("qa!")
end

---@param cfg? cw.UserConfig
function codewars.setup(cfg)
    config.apply(cfg)
    config.setup()

    local theme = require("codewars.theme")
    theme.setup()

    local cmd = require("codewars.command")
    cmd.setup()

    -- VimEnter hook for standalone dashboard mode (nvim codewars.nvim)
    vim.api.nvim_create_autocmd("VimEnter", {
        pattern = "*",
        nested = true,
        callback = function()
            local skip, standalone = codewars.should_skip(true)
            if not skip and standalone then
                local utils = require("codewars.utils")
                utils.exec_hooks("enter")

                local Menu = require("codewars-ui.renderer.menu")
                _Cw_state.menu = Menu:init()
                _Cw_state.menu:mount()
            end
        end,
    })
end

return codewars
