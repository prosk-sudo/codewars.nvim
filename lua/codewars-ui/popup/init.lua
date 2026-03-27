local NuiPopup = require("nui.popup")
local config = require("codewars.config")

---@class cw.ui.Popup : NuiPopup
---@field visible boolean
local Popup = NuiPopup:extend("CwPopup")

function Popup:focus()
    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_set_current_win(self.winid)
    end
end

function Popup:show()
    if not self._.mounted then
        self:mount()
    elseif not self.visible then
        Popup.super.show(self)
    end
    self.visible = true
end

function Popup:hide()
    if not self.visible then return end
    Popup.super.hide(self)
    self.visible = false
end

function Popup:toggle()
    if not self.visible then
        self:show()
    else
        self:hide()
    end
end

function Popup:mount()
    Popup.super.mount(self)
    self.visible = true

    self:on({ "BufLeave", "WinLeave" }, function()
        self:handle_leave()
    end)

    local keys = config.user.keys
    local toggle_keys = type(keys.toggle) == "table" and keys.toggle or { keys.toggle }
    for _, key in ipairs(toggle_keys) do
        self:map("n", key, function()
            self:hide()
        end)
    end
end

function Popup:unmount()
    Popup.super.unmount(self)
    self.visible = false
end

function Popup:handle_leave()
    self:hide()
end

function Popup:init(opts)
    local options = vim.tbl_deep_extend("force", {
        focusable = true,
        border = {
            style = "rounded",
        },
        buf_options = {
            modifiable = false,
            readonly = false,
        },
    }, opts or {})

    self.visible = false
    Popup.super.init(self, options)
end

return Popup
