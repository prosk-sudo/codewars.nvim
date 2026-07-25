local theme = require("codewars.theme")

--- The Codewars profile badge, drawn in text.
---
--- codewars.com serves a real badge at /users/{name}/badges/large, but it is
--- an SVG and Neovim cannot draw one: showing the actual image needs a
--- terminal graphics protocol plus an SVG rasteriser, which would be a hard
--- dependency that silently degrades on every terminal without it. This draws
--- the same information instead — rank, name, honor — in box characters
--- tinted with the rank colour the plugin already defines, so it looks the
--- same everywhere and costs no dependency and no network call.
---
--- The real badge omits the completed count, so that line is kept below
--- rather than dropped.
---@class cw.ui.Badge
local M = {}

local INNER = 39 -- content columns between the side bars

---@param n integer
---@return string
local function spaces(n)
    return string.rep(" ", math.max(0, n))
end

--- Truncate to `limit` display columns, ellipsising when it does not fit.
---@param text string
---@param limit integer
---@return string
local function fit(text, limit)
    if vim.fn.strdisplaywidth(text) <= limit then
        return text
    end
    local out = ""
    for _, char in ipairs(vim.fn.split(text, "\\zs")) do
        if vim.fn.strdisplaywidth(out .. char .. "…") > limit then
            break
        end
        out = out .. char
    end
    return out .. "…"
end

---@class cw.ui.Badge.Result
---@field lines string[]
---@field highlights { row: integer, col_start: integer, col_end: integer, hl: string }[] rows are 0-based within `lines`, columns are BYTE offsets
---@field width integer display width of the badge block

--- Build the badge block. Pure — no buffer, no window, so the geometry and
--- the highlight offsets are testable directly.
---@param opts { username: string, rank_name?: string, rank?: any, honor?: integer, completed?: integer }
---@return cw.ui.Badge.Result
function M.render(opts)
    local rank_hl = theme.rank_hl(opts.rank)
    local rank_name = opts.rank_name
    if not rank_name or rank_name == "" then
        rank_name = theme.rank_str(opts.rank)
    end
    local honor = tostring(opts.honor or 0)

    local bar = string.rep("█", INNER)
    local top = "◢" .. bar .. "◣"
    local bottom = "◥" .. bar .. "◤"

    -- Left "⬢ <rank>", right "<honor> ⬡", username centered in what is left.
    local left = "  ⬢ " .. rank_name
    local right = honor .. " ⬡  "
    local room = INNER - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right)
    local username = fit(opts.username or "", math.max(0, room - 2))
    local user_w = vim.fn.strdisplaywidth(username)
    local lead = math.max(0, math.floor((room - user_w) / 2))
    local trail = math.max(0, room - user_w - lead)

    -- Assemble piece by piece so highlight columns are exact byte offsets.
    local side = "█"
    local middle = side
    local highlights = {}

    local function append(text, hl)
        local start = #middle
        middle = middle .. text
        if hl then
            highlights[#highlights + 1] = { row = 1, col_start = start, col_end = #middle, hl = hl }
        end
    end

    append("  ⬢ ", rank_hl)
    append(rank_name, rank_hl)
    append(spaces(lead))
    append(username, "codewars_header")
    append(spaces(trail))
    append(honor, "codewars_ref")
    append(" ⬡  ", "codewars_ref")
    middle = middle .. side

    -- The frame carries the rank colour: that is what makes it read as a rank
    -- badge rather than a box.
    highlights[#highlights + 1] = { row = 0, col_start = 0, col_end = #top, hl = rank_hl }
    highlights[#highlights + 1] = { row = 2, col_start = 0, col_end = #bottom, hl = rank_hl }

    local lines = { top, middle, bottom }

    local completed = opts.completed
    if type(completed) == "number" then
        local label = ("%d kata completed"):format(completed)
        local pad = math.max(0, math.floor((INNER + 2 - vim.fn.strdisplaywidth(label)) / 2))
        local line = spaces(pad) .. label
        lines[#lines + 1] = line
        highlights[#highlights + 1] = { row = 3, col_start = 0, col_end = #line, hl = "codewars_ref" }
    end

    return { lines = lines, highlights = highlights, width = INNER + 2 }
end

return M
