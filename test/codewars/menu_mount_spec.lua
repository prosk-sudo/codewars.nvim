-- Menu:mount took over whatever buffer was current -- renamed it, made it
-- nofile, replaced its lines -- so a bare :CW from an unsaved file turned
-- that file into the dashboard, and codewars.stop() later force-deleted it.
describe("Menu:mount buffer choice", function()
    package.loaded["codewars.config"] = {
        user = { keys = { toggle = { "q" } }, username = "" },
        lang = "python",
        langs = require("codewars.config.langs"),
        name = "codewars.nvim",
    }
    package.loaded["codewars.logger"] = {
        info = function() end, warn = function() end, error = function() end,
        err = function() end, debug = function() end,
    }
    -- Signed out: mount renders the sign-in page and never fetches anything.
    package.loaded["codewars.cache.cookie"] = { get = function() return nil end }

    package.loaded["codewars-ui.renderer.menu"] = nil
    local Menu = require("codewars-ui.renderer.menu")
    _Cw_state = _Cw_state or {}

    local function mount_here()
        local menu = Menu:init()
        menu:mount()
        return menu
    end

    it("leaves a modified buffer alone and mounts in a scratch buffer", function()
        vim.cmd("tabnew")
        local mine = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(mine, 0, -1, false, { "unsaved work" })
        assert.is_true(vim.bo[mine].modified)

        local menu = mount_here()
        assert.are_not.equal(mine, menu.bufnr)
        assert.are.same({ "unsaved work" }, vim.api.nvim_buf_get_lines(mine, 0, -1, false))
        assert.is_true(vim.bo[mine].modified)
        assert.are.equal("", vim.bo[mine].buftype)
        vim.cmd("tabclose!")
    end)

    it("leaves a real file alone", function()
        local path = vim.fn.tempname() .. ".txt"
        vim.fn.writefile({ "on disk" }, path)
        vim.cmd("tabnew " .. vim.fn.fnameescape(path))
        local file_buf = vim.api.nvim_get_current_buf()

        local menu = mount_here()
        assert.are_not.equal(file_buf, menu.bufnr)
        assert.are.equal(path, vim.api.nvim_buf_get_name(file_buf))
        vim.cmd("tabclose!")
    end)

    it("reuses an empty unnamed buffer (the normal :CW case)", function()
        vim.cmd("tabnew")
        local empty = vim.api.nvim_get_current_buf()
        local menu = mount_here()
        assert.are.equal(empty, menu.bufnr)
        vim.cmd("tabclose!")
    end)
end)
