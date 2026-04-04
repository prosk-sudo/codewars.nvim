local NuiPopup = require("nui.popup")
local config = require("codewars.config")
local log = require("codewars.logger")
local ui_utils = require("codewars-ui.utils")
local theme = require("codewars.theme")

---@class cw.ui.Stats
---@field popup NuiPopup?
---@field visible boolean
local Stats = {}
Stats.__index = Stats

function Stats:show(username)
    username = username or config.user.username

    if username == "" then
        return log.warn("Username not configured")
    end

    local user_api = require("codewars.api.user")
    user_api.get(username, function(res, err)
        if err then
            return log.err(err)
        end

        self:render(res)
    end)
end

---@param data table
function Stats:render(data)
    local lines = {}
    local highlights = {} -- { row, col_start, col_end, hl_group }

    local username = (data.username ~= nil and data.username ~= vim.NIL) and tostring(data.username) or ""
    local name = (data.name ~= nil and data.name ~= vim.NIL) and tostring(data.name) or ""

    local header = "  " .. username
    if name ~= "" then
        header = header .. "  (" .. name .. ")"
    end
    table.insert(lines, header)
    table.insert(highlights, { #lines - 1, 2, 2 + #username, "codewars_warning" })
    if name ~= "" then
        table.insert(highlights, { #lines - 1, 2 + #username + 2, #header, "codewars_ref" })
    end

    table.insert(lines, "")

    if data.ranks and data.ranks.overall then
        local rank = data.ranks.overall
        local rank_hl = theme.rank_hl(rank.rank)
        local rank_line = "  " .. theme.rank_str(rank.rank) .. "  " .. (rank.score or 0) .. " pts"
        table.insert(lines, "  Rank")
        table.insert(highlights, { #lines - 1, 0, -1, "Title" })
        table.insert(lines, rank_line)
        table.insert(highlights, { #lines - 1, 2, 2 + #theme.rank_str(rank.rank), rank_hl })
    end

    table.insert(lines, "")

    local honor = tostring(data.honor or 0)
    local lb = data.leaderboardPosition
    local position = (lb ~= nil and lb ~= vim.NIL) and ("#" .. tostring(lb)) or "N/A"
    local completed = tostring((data.codeChallenges or {}).totalCompleted or 0)
    local authored = tostring((data.codeChallenges or {}).totalAuthored or 0)
    local clan = (data.clan ~= nil and data.clan ~= vim.NIL) and tostring(data.clan) or ""

    table.insert(lines, "  Stats")
    table.insert(highlights, { #lines - 1, 0, -1, "Title" })

    local stats = {
        { "Honor",       honor },
        { "Leaderboard", position },
        { "Completed",   completed },
        { "Authored",    authored },
    }
    if clan ~= "" then
        table.insert(stats, { "Clan", clan })
    end

    for _, stat in ipairs(stats) do
        local label = stat[1]
        local value = stat[2]
        local padding = string.rep(" ", math.max(1, 16 - #label))
        local line = "    " .. label .. padding .. value
        table.insert(lines, line)
        table.insert(highlights, { #lines - 1, 4 + #label + #padding, #line, "codewars_shortcut" })
    end

    table.insert(lines, "")

    if data.ranks and data.ranks.languages then
        table.insert(lines, "  Languages")
        table.insert(highlights, { #lines - 1, 0, -1, "Title" })

        local langs = {}
        for lang_name, lang_data in pairs(data.ranks.languages) do
            table.insert(langs, { name = lang_name, data = lang_data })
        end
        table.sort(langs, function(a, b) return (a.data.score or 0) > (b.data.score or 0) end)

        local max_score = 1
        for _, lang in ipairs(langs) do
            if (lang.data.score or 0) > max_score then
                max_score = lang.data.score or 0
            end
        end

        local icons = require("codewars.icons").get()

        for _, lang in ipairs(langs) do
            local d = lang.data
            local rank_hl = theme.rank_hl(d.rank)
            local score = d.score or 0

            local icon = icons["lang_" .. lang.name] or "#"

            -- Progress bar (scaled to max score, 10 chars wide)
            local bar_width = 10
            local filled = math.floor((score / max_score) * bar_width)
            local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)

            local name_pad = string.rep(" ", math.max(1, 14 - #lang.name))
            local rank_str = theme.rank_str(d.rank)
            local line = "    " .. icon .. " " .. lang.name .. name_pad .. rank_str .. "  " .. bar .. "  " .. score

            table.insert(lines, line)

            local row = #lines - 1
            local lang_hl = "codewars_lang_" .. lang.name
            local icon_end = 4 + #icon
            table.insert(highlights, { row, 4, icon_end, lang_hl })
            local name_start = icon_end + 1
            table.insert(highlights, { row, name_start, name_start + #lang.name, lang_hl })
            local rank_start = name_start + #lang.name + #name_pad
            table.insert(highlights, { row, rank_start, rank_start + #rank_str, rank_hl })
            local bar_start = rank_start + #rank_str + 2
            table.insert(highlights, { row, bar_start, bar_start + #bar, rank_hl })
        end
    end

    local max_line_width = 0
    for _, line in ipairs(lines) do
        local w = vim.fn.strdisplaywidth(line)
        if w > max_line_width then max_line_width = w end
    end

    local popup_width = math.max(50, max_line_width + 6)
    local popup_height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))

    self.popup = NuiPopup({
        enter = true,
        focusable = true,
        relative = "editor",
        position = "50%",
        size = {
            width = popup_width,
            height = popup_height,
        },
        border = {
            style = "rounded",
            text = {
                top = " Statistics ",
                top_align = "center",
            },
        },
        buf_options = {
            modifiable = true,
            readonly = false,
        },
        win_options = {
            winhighlight = "FloatBorder:codewars_header",
        },
    })

    self.popup:mount()
    self.visible = true

    ui_utils.buf_set_lines(self.popup.bufnr, lines)

    local ns = vim.api.nvim_create_namespace("codewars_stats")
    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(self.popup.bufnr, ns, hl[4], hl[1], hl[2], hl[3])
    end

    self.popup:map("n", "q", function() self:hide() end)
    self.popup:map("n", "<Esc>", function() self:hide() end)
    self.popup:on("BufLeave", function() self:hide() end)
end

function Stats:hide()
    if self.popup and self.visible then
        self.popup:unmount()
        self.visible = false
    end
end

function Stats:toggle(username)
    if self.visible then
        self:hide()
    else
        self:show(username)
    end
end

---@return cw.ui.Stats
function Stats:new()
    return setmetatable({ visible = false }, self)
end

return Stats
