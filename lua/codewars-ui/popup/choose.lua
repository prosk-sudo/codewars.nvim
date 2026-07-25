local ui_utils = require("codewars-ui.utils")

--- Centered list picker, the sibling of popup/confirm.
---
--- Same reasoning as the confirm box: `vim.ui.select` hands the list to
--- whatever picker the user installed, which opens a filter prompt and places
--- the window wherever it likes. For a short, fixed list — five kata fields,
--- eight ranks — there is nothing to filter, so this is a plain box you move
--- through with j/k and pick with Enter. Number keys jump straight to a row.
---@class cw.ui.Choose
local M = {}

local MIN_WIDTH = 30
local MAX_WIDTH = 72
local GUTTER = 4 -- "  1 " prefix
local MAX_ROWS = 12

--- Render the rows. Pure, so the box's shape is testable without a window.
---@param title string
---@param items { label: string }[]
---@return { width: integer, height: integer, lines: string[] }
function M.layout(title, items)
    local rows = {}
    for i, item in ipairs(items) do
        -- Rows past 9 lose their shortcut but stay selectable with j/k.
        local key = i <= 9 and tostring(i) or " "
        rows[i] = ("  %s %s"):format(key, item.label)
    end

    local longest = vim.fn.strdisplaywidth(title)
    for _, row in ipairs(rows) do
        longest = math.max(longest, vim.fn.strdisplaywidth(row))
    end
    local ceiling = math.min(MAX_WIDTH, math.max(MIN_WIDTH, vim.o.columns - 8))
    local width = math.max(MIN_WIDTH, math.min(ceiling, longest + GUTTER))

    return { width = width, height = math.min(#rows, MAX_ROWS), lines = rows }
end

--- Open the picker. `cb` gets the chosen item (the table as passed in) or nil
--- when dismissed, and fires exactly once.
---@param opts { title: string, items: { label: string }[] }
---@param cb fun(item: table?, index: integer?)
function M.open(opts, cb)
    local items = opts.items or {}
    if #items == 0 then
        return cb(nil, nil)
    end

    local NuiPopup = require("nui.popup")
    local box = M.layout(opts.title, items)

    local popup = NuiPopup({
        enter = true,
        focusable = true,
        relative = "editor",
        position = "50%",
        size = { width = box.width, height = box.height },
        border = {
            style = "rounded",
            text = { top = " " .. opts.title .. " ", top_align = "center" },
        },
        buf_options = { modifiable = true, readonly = false },
        win_options = { winhighlight = "FloatBorder:codewars_header", cursorline = true },
    })

    popup:mount()
    ui_utils.buf_set_lines(popup.bufnr, box.lines)
    ui_utils.buf_set_opts(popup.bufnr, { modifiable = false, buftype = "nofile", swapfile = false })
    ui_utils.win_set_opts(popup.winid, {
        number = false,
        relativenumber = false,
        cursorline = true,
        signcolumn = "no",
        wrap = false,
    })

    local answered = false
    local function finish(index)
        if answered then
            return
        end
        answered = true
        popup:unmount()
        if index then
            cb(items[index], index)
        else
            cb(nil, nil)
        end
    end

    popup:map("n", "<CR>", function()
        finish(vim.api.nvim_win_get_cursor(popup.winid)[1])
    end, { nowait = true })

    for _, key in ipairs({ "q", "<Esc>" }) do
        popup:map("n", key, function()
            finish(nil)
        end, { nowait = true })
    end

    for i = 1, math.min(#items, 9) do
        popup:map("n", tostring(i), function()
            finish(i)
        end, { nowait = true })
    end

    popup:on("BufLeave", function()
        finish(nil)
    end)
end

return M
