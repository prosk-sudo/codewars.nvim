local Popup = require("codewars-ui.popup")

---@class cw.ui.Console.Popup : cw.ui.Popup
---@field console cw.ui.Console
local ConsolePopup = Popup:extend("CwConsolePopup")

ConsolePopup.handle_leave = vim.schedule_wrap(function(self)
    local curr_bufnr = vim.api.nvim_get_current_buf()
    for _, p in pairs(self.console.popups) do
        if p.bufnr == curr_bufnr then
            return
        end
    end
    self.console:hide()
end)

function ConsolePopup:init(parent, opts)
    ConsolePopup.super.init(self, opts)
    self.console = parent
end

return ConsolePopup
