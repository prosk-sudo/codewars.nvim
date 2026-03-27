local NuiLayout = require("nui.layout")
local Layout = require("codewars-ui.layout")
local Result = require("codewars-ui.popup.console.result")
local Runner = require("codewars.runner")
local config = require("codewars.config")

---@class cw.ui.Console : cw.ui.Layout
---@field kata cw.ui.Kata
---@field result cw.ui.Console.ResultPopup
---@field popups cw.ui.Console.Popup[]
local ConsoleLayout = Layout:extend("CwConsoleLayout")

function ConsoleLayout:unmount()
    ConsoleLayout.super.unmount(self)
    self.result = Result(self)
    self.popups = { self.result }
end

function ConsoleLayout:hide()
    ConsoleLayout.super.hide(self)

    pcall(function()
        local winid = vim.api.nvim_get_current_win()
        if self.kata.description and winid == self.kata.description.winid then
            vim.api.nvim_set_current_win(self.kata.winid)
        elseif self.kata.testcase_split and winid == self.kata.testcase_split.winid then
            vim.api.nvim_set_current_win(self.kata.winid)
        end
    end)
end

function ConsoleLayout:mount()
    self:update(NuiLayout.Box({
        NuiLayout.Box(self.result, { size = "100%" }),
    }, { dir = "row" }))

    ConsoleLayout.super.mount(self)

    self:set_keymaps()
end

function ConsoleLayout:run(mode)
    if mode == "submit" and not self.kata.last_attempt_success then
        local log = require("codewars.logger")
        log.warn("Cannot submit: run :CW attempt first and pass all tests.")
        return
    end

    if config.user.console.open_on_runcode then
        self:show()
    end

    self.result:focus()

    local msg = ({ test = "Running tests...", attempt = "Attempting...", submit = "Submitting..." })[mode]
    self.result:clear(msg)

    Runner:init(self.kata):run(mode)
end

function ConsoleLayout:set_keymaps()
    for _, popup in pairs(self.popups) do
        local keys = config.user.keys
        local toggle_keys = type(keys.toggle) == "table" and keys.toggle or { keys.toggle }
        for _, key in ipairs(toggle_keys) do
            popup:map("n", key, function()
                self:hide()
            end)
        end
    end
end

---@param kata cw.ui.Kata
function ConsoleLayout:init(kata)
    self.kata = kata
    self.result = Result(self)
    self.popups = { self.result }

    ConsoleLayout.super.init(
        self,
        {
            relative = "editor",
            position = "50%",
            size = config.user.console.size,
        },
        NuiLayout.Box({
            NuiLayout.Box(self.result, { size = "100%" }),
        }, { dir = "row" })
    )
end

return ConsoleLayout
