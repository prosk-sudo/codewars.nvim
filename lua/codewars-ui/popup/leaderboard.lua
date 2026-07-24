local theme = require("codewars.theme")
local lb_api = require("codewars.api.leaderboard")

---@class cw.ui.Leaderboard
---@field entries cw.LeaderboardEntry[]
---@field category table
---@field popup NuiPopup?
local Leaderboard = {}
Leaderboard.__index = Leaderboard

-- Display-column caps; longer names/clans are truncated with an ellipsis
local NAME_MAX = 28
local CLAN_MAX = 24

--- Truncate to a display width (handles double-width chars in clan names).
local function truncate(text, max_w)
    if vim.fn.strdisplaywidth(text) <= max_w then
        return text
    end
    local out, i = "", 0
    while true do
        local ch = vim.fn.strcharpart(text, i, 1)
        if ch == "" or vim.fn.strdisplaywidth(out .. ch) > max_w - 1 then
            break
        end
        out = out .. ch
        i = i + 1
    end
    return out .. "…"
end

local function lpad(text, width)
    return string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text))) .. text
end

local function rpad(text, width)
    return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

--- Build aligned lines + highlight spans for a leaderboard table.
--- Pure (no buffer/window access) so it can be unit-tested; byte offsets
--- accumulate per segment so multibyte usernames/clans highlight correctly.
---@param entries cw.LeaderboardEntry[]
---@param value_label string column header for the numeric column ("Honor"/"Score")
---@param total_width integer? target line width; User and Clan expand to fill it
---@return string[] lines, table[] highlights # { row, col_start, col_end, hl_group }, 0-indexed rows
function Leaderboard.format_lines(entries, value_label, total_width)
    local pos_w, rank_w = #"Pos", #"Rank"
    local name_w, clan_w = #"User", #"Clan"
    local honor_w = #value_label

    local rows = {}
    for _, e in ipairs(entries) do
        local row = {
            pos = "#" .. e.position,
            rank = e.rank or "",
            name = e.username,
            clan = e.clan or "",
            honor = e.honor,
            rank_hl = e.rank and theme.rank_hl(lb_api.rank_id(e.rank)) or nil,
        }
        rows[#rows + 1] = row
        pos_w = math.max(pos_w, vim.fn.strdisplaywidth(row.pos))
        rank_w = math.max(rank_w, vim.fn.strdisplaywidth(row.rank))
        name_w = math.max(name_w, math.min(NAME_MAX, vim.fn.strdisplaywidth(row.name)))
        clan_w = math.max(clan_w, math.min(CLAN_MAX, vim.fn.strdisplaywidth(row.clan)))
        honor_w = math.max(honor_w, vim.fn.strdisplaywidth(row.honor))
    end

    -- Pos/Rank/Honor stay content-sized; User and Clan absorb the rest of
    -- the target width (55/45 split) — expanding into surplus space on wide
    -- terminals and squeezing below content width on narrow ones, so the
    -- honor column never overflows out of the popup. Below ~20 usable cols
    -- the terminal is too narrow to matter; keep content widths.
    if total_width then
        local avail = total_width - (2 + pos_w + 2 + rank_w + 2 + 2 + 2 + honor_w)
        if avail >= 20 then
            name_w = math.floor(avail * 0.55)
            clan_w = avail - name_w
        end
    end

    local lines, highlights = {}, {}

    local function push(segments)
        local line = ""
        local row_idx = #lines
        for _, seg in ipairs(segments) do
            if seg[2] then
                highlights[#highlights + 1] = { row_idx, #line, #line + #seg[1], seg[2] }
            end
            line = line .. seg[1]
        end
        lines[#lines + 1] = line
    end

    push({
        { "  " },
        { lpad("Pos", pos_w) .. "  " .. rpad("Rank", rank_w) .. "  " .. rpad("User", name_w)
            .. "  " .. rpad("Clan", clan_w) .. "  " .. lpad(value_label, honor_w), "Title" },
    })
    push({ { "" } })

    for _, row in ipairs(rows) do
        push({
            { "  " },
            { lpad(row.pos, pos_w), "codewars_ref" },
            { "  " },
            { rpad(row.rank, rank_w), row.rank_hl },
            { "  " },
            { rpad(truncate(row.name, name_w), name_w) },
            { "  " },
            { rpad(truncate(row.clan, clan_w), clan_w), "codewars_ref" },
            { "  " },
            { lpad(row.honor, honor_w), "codewars_shortcut" },
        })
    end

    return lines, highlights
end

function Leaderboard:show()
    if #self.entries == 0 then
        return
    end

    -- Lazy so format_lines stays requireable without nui (tests)
    local NuiPopup = require("nui.popup")
    local ui_utils = require("codewars-ui.utils")

    -- Lines fill the popup minus a 2-col right margin (the left margin
    -- is baked into each line's leading spaces)
    local width = math.floor(vim.o.columns * 0.8)
    local lines, highlights = Leaderboard.format_lines(self.entries, self.category.value_label, width - 2)

    self.popup = NuiPopup({
        enter = true,
        focusable = true,
        relative = "editor",
        position = "50%",
        size = {
            width = width,
            height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8)),
        },
        border = {
            style = "rounded",
            text = {
                top = (" Leaderboard — %s (Top %d) "):format(self.category.label, #self.entries),
                top_align = "center",
            },
        },
        buf_options = {
            modifiable = true,
            readonly = false,
        },
        win_options = {
            winhighlight = "FloatBorder:codewars_header",
            cursorline = true,
            wrap = false,
        },
    })

    self.popup:mount()

    ui_utils.buf_set_lines(self.popup.bufnr, lines)

    local ns = vim.api.nvim_create_namespace("codewars_leaderboard")
    for _, hl in ipairs(highlights) do
        pcall(vim.api.nvim_buf_add_highlight, self.popup.bufnr, ns, hl[4], hl[1], hl[2], hl[3])
    end

    self.popup:map("n", "q", function() self:close() end)
    self.popup:map("n", "<Esc>", function() self:close() end)
    self.popup:on("BufLeave", function() self:close() end)
end

function Leaderboard:close()
    if self.popup then
        pcall(function() self.popup:unmount() end)
        self.popup = nil
    end
end

---@param entries cw.LeaderboardEntry[]
---@param category_key string
---@return cw.ui.Leaderboard
function Leaderboard:new(entries, category_key)
    return setmetatable({
        entries = entries,
        category = lb_api.category(category_key) or { label = tostring(category_key), value_label = "Honor" },
    }, self)
end

return Leaderboard
