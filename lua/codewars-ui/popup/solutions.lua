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
---@field id integer                 names this popup's resize augroup
---@field _resize_group integer?     VimResized augroup, present while mounted
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
local MIN_CONTENT = 1 -- content rows a pane keeps at the least
-- Rows one bordered pane needs, and the stack of the code pane plus a
-- second pane, both at MIN_CONTENT, each with its border.
local MIN_PANE = MIN_CONTENT + BORDER
local MIN_STACK = 2 * MIN_PANE

-- Vote keys. Deliberately two-key: `b` and `v` are what a reader presses
-- reflexively in a code buffer (back a word, visual select), and a vote
-- is a public, unconfirmed action against someone else's solution.
Solutions.KEY_BEST_PRACTICE = "gb"
Solutions.KEY_CLEVER = "gv"

local INFO_NS = vim.api.nvim_create_namespace("codewars_solutions_info")

local instances = 0 -- popups created so far; each gets its own resize augroup

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

--- Buffer lines for a flattened comment list (text only; see
--- codewars-ui.popup.comments for the renderer that also paints it).
---@param comments cw.SolutionComment[]
---@return string[]
function Solutions.comment_lines(comments)
    local lines, _ = require("codewars-ui.popup.comments").render(comments)
    return lines
end

--- Geometry for the stacked popups. Comments closed: the code pane with
--- the one-line info box under it. Comments open: the code pane with the
--- comments pane under it (the info box gives way, its hints move into the
--- comments title). Sized from the editor and CLAMPED to it: the box is
--- at least wide enough for the info line (so its hints are never cut
--- off), and the stack never starts above row 0 or ends below the last
--- usable row. Every `row` is a CONTENT row: nui draws each border one row
--- above it, so the stack's top edge is `row - 1`.
---
--- Two bordered panes need MIN_STACK rows. On an editor too short for that
--- the second pane (info box or comments) is dropped, returned as nil, and
--- the code pane takes what fits. One bordered pane needs MIN_PANE rows; on
--- an editor shorter than that nothing fits, so there is no geometry at all
--- (all three nil) and the caller must not open a popup.
---@param sol cw.Solution? the solution whose info line sets the minimum width
---@return table? code_geom, table? info_geom, table? comments_geom
function Solutions:geometry(sol)
    local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
    if rows < MIN_PANE then return nil, nil, nil end
    local min_width = sol and (vim.fn.strdisplaywidth(self:info_line(sol)) + 2) or 20
    local width = math.max(20, math.floor(cols * WIDTH), math.min(min_width, cols - BORDER))
    width = math.min(width, math.max(1, cols - BORDER))
    local col = math.max(0, math.floor((cols - width) / 2))

    local total = math.min(math.max(MIN_STACK, math.floor(rows * HEIGHT)), rows)
    -- At least 1: the top border sits on `row - 1`, which must not be above
    -- the screen. Only a stack that fills (almost) the whole editor is moved.
    local row = math.max(1, math.floor((rows - total) / 2))

    if total < MIN_STACK then
        return { width = width, height = total - BORDER, row = row, col = col }, nil, nil
    end

    if self.show_comments then
        local inner = total - 2 * BORDER
        local comments_h = math.max(MIN_CONTENT, math.floor(inner * COMMENTS_SHARE))
        local code_h = math.max(MIN_CONTENT, inner - comments_h)
        return { width = width, height = code_h, row = row, col = col }, nil,
            { width = width, height = comments_h, row = row + code_h + BORDER, col = col }
    end

    local code_h = total - INFO_HEIGHT - 2 * BORDER
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
    if not code_geom then
        -- Not even one bordered pane fits above the command line. Panes are
        -- already unmounted above, so a popup that no longer fits (the editor
        -- shrank) closes rather than hanging off-screen, and with nothing
        -- left to lay out it stops listening for resizes too.
        self:_unwatch_resize()
        return log.warn("Not enough room to show solutions; make the window taller")
    end

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
        -- Rendered and painted directly (no markdown filetype): every user
        -- sees the same thing regardless of grammars/conceal setup.
        local comments = require("codewars-ui.popup.comments")
        comments.paint(self.comments_popup.bufnr, comments.render(sol.comments or {}))
        self:_bind(self.comments_popup.bufnr)
    end

    self:_watch_resize()
    local target = (self.focus == "comments" and self.comments_popup) or self.popup
    vim.api.nvim_set_current_win(target.winid)
end

--- Listen for the editor being resized for as long as the panes are mounted.
--- The layout is only computed in render(), so without this a terminal
--- resized while the popup is open leaves the panes where they were, past the
--- last row. One group per instance, created on first mount and removed in
--- close() (or when a resize finds nothing left to lay out), so nothing
--- outlives the popup and re-rendering never stacks a second autocmd.
function Solutions:_watch_resize()
    if self._resize_group then return end
    self._resize_group = vim.api.nvim_create_augroup("codewars_solutions_" .. self.id, { clear = true })
    -- Global, not buffer-local: VimResized is not tied to any buffer.
    vim.api.nvim_create_autocmd("VimResized", {
        group = self._resize_group,
        callback = function() self:relayout() end,
    })
end

function Solutions:_unwatch_resize()
    if not self._resize_group then return end
    pcall(vim.api.nvim_del_augroup_by_id, self._resize_group)
    self._resize_group = nil
end

--- True when the pane has a live window. nui clears `winid` itself when a
--- pane's window is closed, so the field can be nil, not just stale.
---@param popup NuiPopup?
---@return boolean
local function on_screen(popup)
    return popup ~= nil and popup.winid ~= nil and vim.api.nvim_win_is_valid(popup.winid)
end

--- A pane's window view (cursor, scroll), or nil if it is not on screen.
---@param popup NuiPopup?
---@return table?
local function save_view(popup)
    if not on_screen(popup) then return nil end
    return vim.api.nvim_win_call(popup.winid, vim.fn.winsaveview)
end

---@param popup NuiPopup?
---@param view table?
local function restore_view(popup, view)
    if not view or not on_screen(popup) then return end
    vim.api.nvim_win_call(popup.winid, function() vim.fn.winrestview(view) end)
end

--- Lay the panes out again for the editor's current size, through the same
--- geometry() and render() as every other redraw, keeping the user's place:
--- the solution, the cursor and scroll of the code and comments panes, and
--- the focused pane. The second pane appears or goes as the room allows, and
--- when not even one pane fits render() closes the popup with its notice.
function Solutions:relayout()
    if not on_screen(self.popup) then
        -- The panes went away some other way: nothing to lay out.
        return self:_unwatch_resize()
    end
    local current = vim.api.nvim_get_current_win()
    if on_screen(self.comments_popup) and current == self.comments_popup.winid then
        self.focus = "comments"
    elseif current == self.popup.winid then
        self.focus = "code"
    end
    local code_view, comments_view = save_view(self.popup), save_view(self.comments_popup)
    self:render()
    restore_view(self.popup, code_view)
    restore_view(self.comments_popup, comments_view)
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
    local name = label == "best_practice" and "Best Practices" or "Clever"
    local retracting = sol.voted and sol.voted[label]
    self._voting = true
    -- Feedback from the keypress itself: a vote on a big kata can sit for
    -- 15 s or more, and without this there is no telling a slow request
    -- from a keystroke that did not register.
    local spinner = require("codewars.logger.spinner"):start(
        (retracting and "Removing your %s vote…" or "Voting %s…"):format(name))
    require("codewars.api.solutions").vote(sol, label, function(votes, err, note)
        self._voting = false
        if err then
            return spinner:error("Vote failed: " .. (err.msg or "unknown error"))
        end
        local v = votes[label] or {}
        local what = v.voted and ("Voted %s (%d)"):format(name, v.count or 0)
            or ("Removed your %s vote (%d)"):format(name, v.count or 0)
        -- The server's reply was unusable and the state was re-read from
        -- the page: say so, the wait was noticeable.
        spinner:success(note and (what .. " — " .. note) or what)
        -- Only refresh if the popup is still open on the same solution.
        if self.popup and self.index == idx then
            self:draw_info(sol)
        end
    end, { progress = function(msg) spinner:update(msg) end })
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
    -- The code pane is up but the comments did not fit under it: say so, and
    -- go back to "comments closed" so the next press asks again instead of
    -- toggling something that was never on screen.
    if self.show_comments and self.popup and not self.comments_popup then
        self.show_comments = false
        self.focus = "code"
        log.info("Not enough room to show comments; make the window taller")
    end
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
    self:_unwatch_resize()
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
    instances = instances + 1
    return setmetatable({
        id = instances, -- names this popup's resize augroup
        solutions = items,
        language = language,
        index = 1,
        show_comments = false,
        focus = "code",
    }, self)
end

return Solutions
