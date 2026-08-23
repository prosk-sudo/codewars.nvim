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

-- Vote keys. Deliberately two-key: `b` and `v` are what a reader presses
-- reflexively in a code buffer (back a word, visual select), and a vote
-- is a public, unconfirmed action against someone else's solution.
Solutions.KEY_BEST_PRACTICE = "gb"
Solutions.KEY_CLEVER = "gv"

local INFO_NS = vim.api.nvim_create_namespace("codewars_solutions_info")

function Solutions:show()
    if #self.solutions == 0 then
        return log.info("No solutions available")
    end

    self:render()
end

--- Fetch a kata's solutions with a spinner and open the popup. Shared by
--- `:CW solutions` and the post-submit auto-open; the empty and error
--- cases are worded here once.
---@param kata { kata_id: string, lang: string, rank: integer? }
function Solutions.fetch_and_show(kata)
    local solutions_api = require("codewars.api.solutions")
    -- Codewars ranks the solutions server-side before answering: 1-3 s for
    -- most kata, up to ~7 s for the most-solved ones. The spinner says the
    -- wait is expected.
    local spinner = require("codewars.logger.spinner"):start("Fetching solutions…")
    solutions_api.fetch(kata.kata_id, kata.lang, function(sols, err)
        if err then
            return spinner:error("Failed to fetch solutions: " .. (err.msg or "unknown error"))
        end
        if not sols or #sols == 0 then
            -- solutions.fetch already logged the accurate reason (locked /
            -- none yet / beta pending / drift). Close the spinner on a
            -- neutral note rather than leaving "Fetching…" on screen.
            return spinner:success("No solutions to show")
        end
        spinner:success(("%d solutions"):format(#sols))
        Solutions:new(sols, kata.lang):show()
    end, { unranked = require("codewars.theme").is_unranked(kata.rank) })
end

--- The single line shown in the info box under the code.
---@param sol cw.Solution
---@return string
function Solutions:info_line(sol)
    local line, _ = self:info_segments(sol)
    return line
end

--- The info line as text plus highlight spans ({col_start, col_end, group},
--- byte columns), so labels read as normal text, counts stand out, keys
--- look like keys, and the voted icon is green.
---@param sol cw.Solution
---@return string line, { [1]: integer, [2]: integer, [3]: string }[] spans
function Solutions:info_segments(sol)
    local icons = require("codewars.icons").get()
    local votes, voted = sol.votes or {}, sol.voted or {}
    local n = sol.total_comments or #(sol.comments or {})

    local parts, spans = {}, {}
    local col = 0
    local function add(text, group)
        parts[#parts + 1] = text
        if group then spans[#spans + 1] = { col, col + #text, group } end
        col = col + #text
    end
    local sep = function() add("  ·  ", "codewars_ref") end

    local function label(text, key, count, mine)
        if mine then add(icons.voted .. " ", "codewars_ok") end
        add(text .. " ", mine and "codewars_ok" or "codewars_normal")
        add(tostring(count or 0), "codewars_info")
        add(" ")
        add("[" .. key .. "]", "codewars_hint_key")
    end

    label("Best Practices", Solutions.KEY_BEST_PRACTICE, votes.best_practice, voted.best_practice)
    sep()
    label("Clever", Solutions.KEY_CLEVER, votes.clever, voted.clever)
    sep()
    add(("%d comment%s"):format(n, n == 1 and "" or "s"), "codewars_normal")
    if n > 0 then
        add(" ")
        add("[c]", "codewars_hint_key")
        add(self.show_comments and " hide" or " show", "codewars_normal")
    end

    return table.concat(parts), spans
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
--- comments title). Sized from the editor and CLAMPED to it: the box is
--- at least wide enough for the info line (so its hints are never cut
--- off) and never taller than the screen or placed above row 0.
---@param sol cw.Solution? the solution whose info line sets the minimum width
---@return table code_geom, table? info_geom, table? comments_geom
function Solutions:geometry(sol)
    local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
    local min_width = sol and (vim.fn.strdisplaywidth(self:info_line(sol)) + 2) or 20
    local width = math.max(20, math.floor(cols * WIDTH), math.min(min_width, cols - BORDER))
    width = math.min(width, math.max(1, cols - BORDER))
    local col = math.max(0, math.floor((cols - width) / 2))

    local total = math.min(math.max(6, math.floor(rows * HEIGHT)), math.max(1, rows))
    local row = math.max(0, math.floor((rows - total) / 2))

    if self.show_comments then
        local inner = math.max(2, total - 2 * BORDER)
        local comments_h = math.max(1, math.floor(inner * COMMENTS_SHARE))
        local code_h = math.max(1, inner - comments_h)
        return { width = width, height = code_h, row = row, col = col }, nil,
            { width = width, height = comments_h, row = row + code_h + BORDER, col = col }
    end

    local code_h = math.max(1, total - INFO_HEIGHT - 2 * BORDER)
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

--- (Re)write the info box from the solution's current votes. Cheap and
--- in place, so a vote never rebuilds the panes or moves the cursor.
---@param sol cw.Solution
function Solutions:draw_info(sol)
    if not self.info_popup or not vim.api.nvim_buf_is_valid(self.info_popup.bufnr) then return end
    local line, spans = self:info_segments(sol)
    ui_utils.buf_set_lines(self.info_popup.bufnr, { line })
    vim.api.nvim_buf_clear_namespace(self.info_popup.bufnr, INFO_NS, 0, -1)
    for _, s in ipairs(spans) do
        vim.api.nvim_buf_add_highlight(self.info_popup.bufnr, INFO_NS, s[3], 0, s[1], s[2])
    end
end

function Solutions:render()
    self:_unmount_popups()

    local sol = self.solutions[self.index]
    local code_geom, info_geom, comments_geom = self:geometry(sol)

    self.popup = make_popup(code_geom, (" Solution %d/%d "):format(self.index, #self.solutions))
    self.popup:mount()
    ui_utils.buf_set_lines(self.popup.bufnr, vim.split(sol.code or "", "\n", { plain = true }))
    Solutions.highlight(self.popup.bufnr, require("codewars.languages.filetypes").code(self.language))
    self:_bind(self.popup.bufnr)

    if info_geom then
        self.info_popup = make_popup(info_geom, nil)
        self.info_popup:mount()
        self:draw_info(sol)
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
    vim.keymap.set("n", Solutions.KEY_BEST_PRACTICE, function() self:vote("best_practice") end, opts)
    vim.keymap.set("n", Solutions.KEY_CLEVER, function() self:vote("clever") end, opts)
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

--- Vote the current solution as `label`, or retract it if already voted.
--- Only the info box is redrawn from the server's reply — the code pane
--- keeps its cursor and scroll. A second press while the request is in
--- flight is ignored rather than queued.
---@param label "best_practice"|"clever"
function Solutions:vote(label)
    if self._voting then return end
    local sol = self.solutions[self.index]
    local idx = self.index
    self._voting = true
    require("codewars.api.solutions").vote(sol, label, function(votes, err, note)
        self._voting = false
        if err then
            return log.error("Vote failed: " .. (err.msg or "unknown error"))
        end
        local name = label == "best_practice" and "Best Practices" or "Clever"
        local v = votes[label] or {}
        local what = v.voted and ("Voted %s (%d)"):format(name, v.count or 0)
            or ("Removed your %s vote (%d)"):format(name, v.count or 0)
        -- The server's reply was unusable and the state was re-read from
        -- the page: say so, the wait was noticeable.
        log.info(note and (what .. " — " .. note) or what)
        -- Only refresh if the popup is still open on the same solution.
        if self.popup and self.index == idx then
            self:draw_info(sol)
        end
    end)
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
            items[#items + 1] = {
                code = s, authors = {}, extra_authors = 0, comments = {}, total_comments = 0,
                votes = { best_practice = 0, clever = 0 }, voted = { best_practice = false, clever = false },
            }
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
