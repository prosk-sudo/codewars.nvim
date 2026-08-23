local NuiPopup = require("nui.popup")
local log = require("codewars.logger")
local ui_utils = require("codewars-ui.utils")

---@class cw.ui.Solutions
---@field solutions string[]
---@field language string
---@field index integer
---@field popup NuiPopup?
local Solutions = {}
Solutions.__index = Solutions

function Solutions:show()
    if #self.solutions == 0 then
        return log.info("No solutions available")
    end

    self:render()
end

function Solutions:render()
    if self.popup then
        pcall(function() self.popup:unmount() end)
    end

    self.popup = NuiPopup({
        enter = true,
        focusable = true,
        relative = "editor",
        position = "50%",
        size = {
            width = "80%",
            height = "70%",
        },
        border = {
            style = "rounded",
            text = {
                top = (" Code (%d/%d) "):format(self.index, #self.solutions),
                top_align = "center",
            },
        },
        buf_options = {
            modifiable = false,
            readonly = false,
        },
        win_options = {
            winhighlight = "FloatBorder:codewars_header",
        },
    })

    self.popup:mount()

    -- Scratch buffer, so the filetype must be set by name. config.langs'
    -- `ft` is the file EXTENSION ("py"), which matches no syntax file and
    -- left the popup unhighlighted for most languages.
    local ft = require("codewars.languages.filetypes").code(self.language)
    if ft then
        vim.api.nvim_set_option_value("filetype", ft, { buf = self.popup.bufnr })
    end

    local code = self.solutions[self.index] or ""
    local lines = vim.split(code, "\n", { plain = true })

    ui_utils.buf_set_lines(self.popup.bufnr, lines)

    local opts = { buffer = self.popup.bufnr, silent = true, nowait = true }

    for i = 1, 9 do
        vim.keymap.set("n", tostring(i), function() self:jump_to(i) end, opts)
    end
    vim.keymap.set("n", "0", function() self:jump_to(10) end, opts)

    vim.keymap.set("n", "q", function() self:close() end, opts)
    vim.keymap.set("n", "<Esc>", function() self:close() end, opts)

    self.popup:on("BufLeave", function()
        self:close()
    end)
end

function Solutions:jump_to(n)
    if n >= 1 and n <= #self.solutions then
        self.index = n
        self:render()
    end
end

function Solutions:close()
    if self.popup then
        pcall(function() self.popup:unmount() end)
        self.popup = nil
    end
end

---@param solutions string[]
---@param language string
---@return cw.ui.Solutions
function Solutions:new(solutions, language)
    return setmetatable({
        solutions = solutions,
        language = language,
        index = 1,
    }, self)
end

return Solutions
