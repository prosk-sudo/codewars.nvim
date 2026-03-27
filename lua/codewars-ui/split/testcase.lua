local NuiSplit = require("nui.split")
local config = require("codewars.config")
local ui_utils = require("codewars-ui.utils")

---@class cw.ui.TestcaseSplit
---@field kata cw.ui.Kata
---@field split NuiSplit?
---@field winid integer?
---@field bufnr integer?
---@field visible boolean
---@field original_fixture string
local TestcaseSplit = {}
TestcaseSplit.__index = TestcaseSplit

function TestcaseSplit:mount()
    self.split = NuiSplit({
        relative = "win",
        position = config.user.testcase.position,
        size = config.user.testcase.size,
        enter = false,
        focusable = true,
        buf_options = {
            modifiable = true,
            readonly = false,
        },
    })

    self.split:mount()
    self.winid = self.split.winid
    self.bufnr = self.split.bufnr

    ui_utils.buf_set_opts(self.bufnr, {
        buflisted = false,
        swapfile = false,
        buftype = "nofile",
    })

    ui_utils.win_set_opts(self.winid, {
        wrap = true,
        linebreak = true,
        colorcolumn = "",
        foldlevel = 999,
        number = true,
        relativenumber = false,
        signcolumn = "no",
    })

    -- Set filetype for syntax highlighting
    local utils = require("codewars.utils")
    local lang = utils.get_lang(self.kata.lang)
    if lang then
        vim.api.nvim_set_option_value("filetype", lang.ft, { buf = self.bufnr })
    end

    self.visible = true

    -- Keymaps
    local keys = config.user.keys
    self.split:map("n", keys.toggle, function()
        self:toggle()
    end)

    return self
end

function TestcaseSplit:populate(fixture)
    self.original_fixture = fixture or ""

    if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    local lines = vim.split(self.original_fixture, "\n")
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)

    vim.api.nvim_buf_set_name(self.bufnr, "Test Cases")
end

function TestcaseSplit:content()
    if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
        return self.original_fixture or ""
    end

    local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
    return table.concat(lines, "\n")
end

function TestcaseSplit:reset()
    if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
        local lines = vim.split(self.original_fixture or "", "\n")
        vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
    end
end

function TestcaseSplit:focus()
    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_set_current_win(self.winid)
    end
end

function TestcaseSplit:toggle()
    if self.visible then
        self:hide()
    else
        self:show()
    end
end

function TestcaseSplit:show()
    if self.visible then return end

    if not self.split or not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
        self:mount()
        if self.original_fixture and self.original_fixture ~= "" then
            self:populate(self.original_fixture)
        end
    else
        self.split:show()
        self.visible = true
    end
end

function TestcaseSplit:hide()
    if not self.visible then return end
    if self.split then
        self.split:unmount()
        self.split = nil
    end
    self.visible = false
end

function TestcaseSplit:unmount()
    if self.split then
        self.split:unmount()
        self.split = nil
    end
    self.visible = false
end

---@param kata cw.ui.Kata
---@return cw.ui.TestcaseSplit
function TestcaseSplit:new(kata)
    local obj = setmetatable({}, self)
    obj.kata = kata
    obj.visible = false
    obj.original_fixture = ""
    return obj
end

return TestcaseSplit
