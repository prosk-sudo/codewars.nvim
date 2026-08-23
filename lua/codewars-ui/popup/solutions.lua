local NuiPopup = require("nui.popup")
local log = require("codewars.logger")
local ui_utils = require("codewars-ui.utils")

---@class cw.ui.Solutions
---@field solutions cw.Solution[]
---@field language string
---@field index integer
---@field popup NuiPopup?          code pane
---@field info_popup NuiPopup?     one-line votes / comments box under the code
---@field comments_popup NuiPopup? comment thread, toggled with `c`
---@field show_comments boolean
---@field focus "code"|"comments"
local Solutions = {}
Solutions.__index = Solutions

-- Size of the whole stack as a fraction of the editor. The info box is a
-- single line; with the comments pane open it takes this share of what
-- remains, the code pane the rest.
local WIDTH = 0.8
local HEIGHT = 0.7
local COMMENTS_SHARE = 0.4
local INFO_HEIGHT = 1
local BORDER = 2 -- rows a bordered popup costs beyond its content

function Solutions:show()
    if #self.solutions == 0 then
        return log.info("No solutions available")
    end

    self:render()
end

--- The single line shown in the info box under the code.
---@param sol cw.Solution
---@return string
function Solutions:info_line(sol)
    local votes = sol.votes or {}
    local n = sol.total_comments or #(sol.comments or {})
    local comments = ("%d comment%s"):format(n, n == 1 and "" or "s")
    if n > 0 then
        comments = comments .. (self.show_comments and "  [c] hide" or "  [c] show")
    end
    return table.concat({
        ("Best Practices %d"):format(votes.best_practice or 0),
        ("Clever %d"):format(votes.clever or 0),
        comments,
    }, "    ·    ")
end

--- Buffer lines for a flattened comment list. Replies indent by depth;
--- each header carries author, rank, date and score so a thread reads top
--- to bottom like the site.
---@param comments cw.SolutionComment[]
---@return string[]
function Solutions.comment_lines(comments)
    if #comments == 0 then
        return { "No comments yet." }
    end
    local lines = {}
    for _, c in ipairs(comments) do
        local depth = c.depth or 0
        local indent = string.rep("  ", depth)
        local meta = {}
        if c.rank and c.rank ~= "" then meta[#meta + 1] = c.rank end
        if c.created then meta[#meta + 1] = c.created end
        if (c.score or 0) ~= 0 then meta[#meta + 1] = ("▲ %d"):format(c.score) end
        local header = indent .. (depth > 0 and "↳ " or "● ") .. "**" .. (c.author or "?") .. "**"
        if #meta > 0 then header = header .. "  _" .. table.concat(meta, " · ") .. "_" end
        if c.masked then header = header .. "  [spoiler]" end
        lines[#lines + 1] = header
        for _, l in ipairs(vim.split(c.body or "", "\n", { plain = true })) do
            lines[#lines + 1] = indent .. "  " .. l
        end
        lines[#lines + 1] = ""
    end
    return lines
end

--- Geometry for the stacked popups. Comments closed: the code pane with
--- the one-line info box under it. Comments open: the code pane with the
--- comments pane under it (the info box gives way, its hints move into the
--- comments title). All sized from the editor so the panes split one
--- footprint instead of overlapping.
---@return table code_geom, table? info_geom, table? comments_geom
function Solutions:geometry()
    local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
    local width = math.max(20, math.floor(cols * WIDTH))
    local total = math.max(10, math.floor(rows * HEIGHT))
    local col = math.floor((cols - width) / 2)
    local row = math.floor((rows - total) / 2)

    if self.show_comments then
        local comments_h = math.max(3, math.floor((total - BORDER) * COMMENTS_SHARE))
        local code_h = math.max(3, total - comments_h - 2 * BORDER)
        return { width = width, height = code_h, row = row, col = col }, nil,
            { width = width, height = comments_h, row = row + code_h + BORDER, col = col }
    end

    local code_h = math.max(3, total - INFO_HEIGHT - 2 * BORDER)
    return { width = width, height = code_h, row = row, col = col },
        { width = width, height = INFO_HEIGHT, row = row + code_h + BORDER, col = col }, nil
end

local function make_popup(geom, title, wrap)
    return NuiPopup({
        enter = false,
        focusable = true,
        relative = "editor",
        position = { row = geom.row, col = geom.col },
        size = { width = geom.width, height = geom.height },
        border = {
            style = "rounded",
            -- Always pass a title (even an empty one): nui then draws the
            -- border in its own window, which it places one row/col above
            -- the position. A native-bordered float is placed AT the
            -- position instead, and mixing the two left a one-row gap above
            -- the info box and a one-row overlap below it.
            text = { top = title or "", top_align = "center" },
        },
        buf_options = {
            modifiable = false,
            readonly = false,
        },
        win_options = {
            winhighlight = "FloatBorder:codewars_header",
            wrap = wrap == true,
            linebreak = true,
        },
    })
end

--- Highlight a scratch buffer as `lang` WITHOUT setting 'filetype'.
--- Setting the filetype fires FileType, which runs ftplugins and attaches
--- every LSP configured for that language to a throwaway buffer — that is
--- what made the popup slow to open. Treesitter when a parser exists,
--- the plain syntax file otherwise; both are highlight-only.
---@param bufnr integer
---@param ft string? filetype NAME (e.g. "python"), nil for none
function Solutions.highlight(bufnr, ft)
    if not ft or ft == "" then return end
    local lang = vim.treesitter.language.get_lang and vim.treesitter.language.get_lang(ft) or ft
    local ok = pcall(vim.treesitter.start, bufnr, lang)
    if not ok then
        vim.api.nvim_set_option_value("syntax", ft, { buf = bufnr })
    end
end

function Solutions:render()
    self:_unmount_popups()

    local sol = self.solutions[self.index]
    local code_geom, info_geom, comments_geom = self:geometry()

    self.popup = make_popup(code_geom, (" Solution %d/%d "):format(self.index, #self.solutions))
    self.popup:mount()
    ui_utils.buf_set_lines(self.popup.bufnr, vim.split(sol.code or "", "\n", { plain = true }))
    Solutions.highlight(self.popup.bufnr, require("codewars.languages.filetypes").code(self.language))
    self:_bind(self.popup.bufnr)

    if info_geom then
        self.info_popup = make_popup(info_geom, nil)
        self.info_popup:mount()
        ui_utils.buf_set_lines(self.info_popup.bufnr, { self:info_line(sol) })
        vim.api.nvim_set_option_value("winhighlight", "FloatBorder:codewars_header,Normal:Comment", { win = self.info_popup.winid })
        self:_bind(self.info_popup.bufnr)
    end

    if comments_geom then
        -- The info box is hidden while the thread is open (its count would
        -- only repeat this title), so the hints live here.
        local n = sol.total_comments or #(sol.comments or {})
        self.comments_popup = make_popup(
            comments_geom,
            (" %d comment%s  ·  [c] hide  ·  <Tab> switch pane "):format(n, n == 1 and "" or "s"),
            true
        )
        self.comments_popup:mount()
        ui_utils.buf_set_lines(self.comments_popup.bufnr, Solutions.comment_lines(sol.comments or {}))
        Solutions.highlight(self.comments_popup.bufnr, "markdown")
        self:_bind(self.comments_popup.bufnr)
    end

    local target = (self.focus == "comments" and self.comments_popup) or self.popup
    vim.api.nvim_set_current_win(target.winid)
end

--- True when `bufnr` belongs to one of our panes.
---@param bufnr integer
---@return boolean
function Solutions:_owns(bufnr)
    for _, key in ipairs({ "popup", "info_popup", "comments_popup" }) do
        if self[key] and self[key].bufnr == bufnr then return true end
    end
    return false
end

--- Keymaps and the leave-to-close autocmd, identical on every pane.
---@param bufnr integer
function Solutions:_bind(bufnr)
    local opts = { buffer = bufnr, silent = true, nowait = true }

    for i = 1, 9 do
        vim.keymap.set("n", tostring(i), function() self:jump_to(i) end, opts)
    end
    vim.keymap.set("n", "0", function() self:jump_to(10) end, opts)
    vim.keymap.set("n", "]", function() self:jump_to(self.index + 1) end, opts)
    vim.keymap.set("n", "[", function() self:jump_to(self.index - 1) end, opts)
    vim.keymap.set("n", "c", function() self:toggle_comments() end, opts)
    vim.keymap.set("n", "<Tab>", function() self:switch_pane() end, opts)
    vim.keymap.set("n", "q", function() self:close() end, opts)
    vim.keymap.set("n", "<Esc>", function() self:close() end, opts)

    -- Close when focus leaves the popups altogether, but not when it just
    -- moves between panes (or during a re-render).
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = bufnr,
        callback = function()
            vim.schedule(function()
                if not self.popup then return end
                local cur = vim.api.nvim_get_current_buf()
                if cur == self.popup.bufnr then
                    self.focus = "code"
                elseif self.comments_popup and cur == self.comments_popup.bufnr then
                    self.focus = "comments"
                elseif not self:_owns(cur) then
                    self:close()
                end
            end)
        end,
    })
end

function Solutions:toggle_comments()
    local sol = self.solutions[self.index]
    local n = sol.total_comments or #(sol.comments or {})
    if n == 0 and not self.show_comments then
        return log.info("This solution has no comments")
    end
    self.show_comments = not self.show_comments
    self.focus = self.show_comments and "comments" or "code"
    self:render()
end

function Solutions:switch_pane()
    if not self.comments_popup then return end
    local cur = vim.api.nvim_get_current_win()
    local target = cur == self.popup.winid and self.comments_popup or self.popup
    vim.api.nvim_set_current_win(target.winid)
end

function Solutions:jump_to(n)
    if n >= 1 and n <= #self.solutions and n ~= self.index then
        self.index = n
        self:render()
    end
end

function Solutions:_unmount_popups()
    for _, key in ipairs({ "comments_popup", "info_popup", "popup" }) do
        if self[key] then
            pcall(function() self[key]:unmount() end)
            self[key] = nil
        end
    end
end

function Solutions:close()
    self:_unmount_popups()
end

--- Accepts structured solutions (cw.Solution[]) or, for older callers
--- and tests, a plain list of code strings.
---@param solutions (cw.Solution|string)[]
---@param language string
---@return cw.ui.Solutions
function Solutions:new(solutions, language)
    local items = {}
    for _, s in ipairs(solutions or {}) do
        if type(s) == "string" then
            items[#items + 1] = { code = s, authors = {}, extra_authors = 0, comments = {}, total_comments = 0 }
        else
            items[#items + 1] = s
        end
    end
    return setmetatable({
        solutions = items,
        language = language,
        index = 1,
        show_comments = false,
        focus = "code",
    }, self)
end

return Solutions
