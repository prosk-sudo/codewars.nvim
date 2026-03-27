local NuiSplit = require("nui.split")
local config = require("codewars.config")
local ui_utils = require("codewars-ui.utils")
local theme = require("codewars.theme")

---@class cw.ui.Description
---@field kata cw.ui.Kata
---@field winid integer?
---@field bufnr integer?
---@field visible boolean
local Description = {}
Description.__index = Description

function Description:mount()
    local position = config.user.description.position
    local width = config.user.description.width

    self.split = NuiSplit({
        relative = "editor",
        position = position,
        size = width,
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

    self:populate()

    ui_utils.buf_set_opts(self.bufnr, {
        modifiable = false,
        buflisted = false,
        swapfile = false,
        buftype = "nofile",
        filetype = "markdown",
    })

    ui_utils.win_set_opts(self.winid, {
        wrap = true,
        linebreak = true,
        colorcolumn = "",
        foldlevel = 999,
        conceallevel = 2,
        concealcursor = "nc",
        cursorcolumn = false,
        cursorline = false,
        number = false,
        relativenumber = false,
        list = false,
        spell = false,
        signcolumn = "no",
    })

    self.visible = true

    local keys = config.user.keys
    self.split:map("n", keys.toggle, function()
        self:toggle()
    end)

    return self
end

function Description:populate()
    if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    local kata = self.kata
    local lines = {}

    local rank_str = ""
    if kata.rank then
        rank_str = " [" .. theme.rank_str(kata.rank) .. "]"
    end
    local stats_str = ""
    local stats_hl = nil
    if kata.total_completed and kata.total_attempts and kata.total_attempts > 0 then
        local pct = kata.total_completed * 100 / kata.total_attempts
        stats_str = (" (%d/%d, %.1f%%)"):format(kata.total_completed, kata.total_attempts, pct)
        if pct >= 75 then stats_hl = "codewars_rank_white"
        elseif pct >= 50 then stats_hl = "codewars_rank_yellow"
        elseif pct >= 25 then stats_hl = "codewars_rank_blue"
        else stats_hl = "codewars_rank_purple"
        end
    end
    local header = "# " .. (kata.name or kata.slug) .. rank_str .. stats_str
    table.insert(lines, header)
    table.insert(lines, "")

    if kata.tags and #kata.tags > 0 then
        table.insert(lines, "**Tags:** " .. table.concat(kata.tags, ", "))
        table.insert(lines, "")
    end

    table.insert(lines, "[Open on Codewars](https://www.codewars.com/kata/" .. kata.slug .. ")")
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")

    if kata.description_text then
        for line in kata.description_text:gmatch("[^\r\n]*") do
            table.insert(lines, line)
        end
    end

    ui_utils.buf_set_lines(self.bufnr, lines)

    if stats_hl and stats_str ~= "" then
        local header_text = lines[1] or ""
        local stats_start = header_text:find(stats_str, 1, true)
        if stats_start then
            vim.api.nvim_buf_add_highlight(self.bufnr, -1, stats_hl, 0, stats_start - 1, -1)
        end
    end
end

function Description:toggle()
    if self.visible then
        self:hide()
    else
        self:show()
    end
end

function Description:show()
    if self.visible then return end

    if not self.split or not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
        self:mount()
    else
        self.split:show()
        self.visible = true
    end
end

function Description:hide()
    if not self.visible then return end
    if self.split then
        self.split:unmount()
        self.split = nil
    end
    self.visible = false
end

function Description:unmount()
    if self.split then
        self.split:unmount()
        self.split = nil
    end
    self.visible = false
end

---@param kata cw.ui.Kata
---@return cw.ui.Description
function Description:new(kata)
    local obj = setmetatable({}, self)
    obj.kata = kata
    obj.visible = false
    return obj
end

return Description
