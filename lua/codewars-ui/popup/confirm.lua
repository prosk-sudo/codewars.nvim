local ui_utils = require("codewars-ui.utils")

--- Centered yes/no confirmation popup.
---
--- `vim.ui.select` was the obvious tool, but it routes a two-choice question
--- through whatever picker the user has installed, which renders a prompt
--- INPUT — you type to filter two fixed options. For an irreversible action
--- that is noise, and the box lands wherever the picker puts it rather than in
--- the middle of the screen. This is a plain confirm box instead: centered on
--- the editor, text centered inside it, `y`/`Enter` to confirm, `n`/`q`/`Esc`
--- to cancel.
---@class cw.ui.Confirm
local M = {}

local MIN_WIDTH = 34
local MAX_WIDTH = 72
local PADDING = 4 -- 2 columns of breathing room each side

--- Pad a line so it sits centered in `width` display columns. Uses display
--- width, not #s: the prompts carry curly quotes and em dashes.
---@param line string
---@param width integer
---@return string
local function center(line, width)
    local pad = math.floor((width - vim.fn.strdisplaywidth(line)) / 2)
    return pad > 0 and (string.rep(" ", pad) .. line) or line
end

--- Split a message into lines that fit `width`, breaking on spaces.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
    local lines = {}
    for paragraph in (text .. "\n"):gmatch("([^\n]*)\n") do
        if paragraph == "" then
            lines[#lines + 1] = ""
        else
            local line = ""
            for word in paragraph:gmatch("%S+") do
                local candidate = line == "" and word or (line .. " " .. word)
                if vim.fn.strdisplaywidth(candidate) > width and line ~= "" then
                    lines[#lines + 1] = line
                    line = word
                else
                    line = candidate
                end
            end
            lines[#lines + 1] = line
        end
    end
    return lines
end

--- Compute the box: wrapped, horizontally centered lines plus the key hint.
--- Pure, so the geometry is testable without a window ever existing.
---@param message string
---@param opts? { confirm?: string, cancel?: string }
---@return { width: integer, height: integer, lines: string[] }
function M.layout(message, opts)
    opts = opts or {}
    local hint = ("[y] %s    [n] %s"):format(opts.confirm or "Confirm", opts.cancel or "Cancel")

    -- Width is driven by the longest natural line, clamped to the screen.
    local ceiling = math.min(MAX_WIDTH, math.max(MIN_WIDTH, vim.o.columns - 8))
    local longest = vim.fn.strdisplaywidth(hint)
    for _, line in ipairs(wrap(message, ceiling - PADDING)) do
        longest = math.max(longest, vim.fn.strdisplaywidth(line))
    end
    local width = math.max(MIN_WIDTH, math.min(ceiling, longest + PADDING))

    local lines = { "" }
    for _, line in ipairs(wrap(message, width - PADDING)) do
        lines[#lines + 1] = center(line, width)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = center(hint, width)
    lines[#lines + 1] = ""

    return { width = width, height = #lines, lines = lines }
end

--- Ask the question. `cb` receives true only for an explicit confirm, and is
--- called exactly once however the popup is dismissed.
---@param opts { message: string, title?: string, confirm?: string, cancel?: string }
---@param cb fun(confirmed: boolean)
function M.open(opts, cb)
    local NuiPopup = require("nui.popup")
    local box = M.layout(opts.message, opts)

    local popup = NuiPopup({
        enter = true,
        focusable = true,
        relative = "editor",
        position = "50%", -- dead center, not wherever a picker would land
        size = { width = box.width, height = box.height },
        border = {
            style = "rounded",
            text = { top = " " .. (opts.title or "Confirm") .. " ", top_align = "center" },
        },
        buf_options = { modifiable = true, readonly = false },
        win_options = { winhighlight = "FloatBorder:codewars_header", cursorline = false },
    })

    popup:mount()
    ui_utils.buf_set_lines(popup.bufnr, box.lines)
    ui_utils.buf_set_opts(popup.bufnr, { modifiable = false, buftype = "nofile", swapfile = false })
    ui_utils.win_set_opts(popup.winid, {
        number = false,
        relativenumber = false,
        cursorline = false,
        cursorcolumn = false,
        signcolumn = "no",
        wrap = false,
    })

    local answered = false
    local function finish(confirmed)
        if answered then
            return
        end
        answered = true
        popup:unmount()
        cb(confirmed)
    end

    for _, key in ipairs({ "y", "Y", "<CR>" }) do
        popup:map("n", key, function()
            finish(true)
        end, { nowait = true })
    end
    for _, key in ipairs({ "n", "N", "q", "<Esc>" }) do
        popup:map("n", key, function()
            finish(false)
        end, { nowait = true })
    end
    -- Leaving the popup any other way counts as "no".
    popup:on("BufLeave", function()
        finish(false)
    end)
end

return M
