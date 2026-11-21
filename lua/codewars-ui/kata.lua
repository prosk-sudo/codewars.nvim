local Description = require("codewars-ui.split.description")
local TestcaseSplit = require("codewars-ui.split.testcase")
local Console = require("codewars-ui.layout.console")
local config = require("codewars.config")
local utils = require("codewars.utils")
local ui_utils = require("codewars-ui.utils")
local log = require("codewars.logger")
local session_cache = require("codewars.cache.session")

---@class cw.ui.Kata
---@field slug string
---@field lang string
---@field name string?
---@field rank integer?
---@field tags string[]?
---@field description_text string?
---@field setup_code string?
---@field example_fixture string?
---@field test_framework string?
---@field language_version string?
---@field kata_path string?
---@field solution_id string
---@field bufnr integer?
---@field winid integer?
---@field file Path?
---@field _picked_file string? solution file the user chose, to open rather than the one the slug names
---@field description cw.ui.Description
---@field console cw.ui.Console
---@field last_attempt_success boolean
---@field finalized boolean
local Kata = {}
Kata.__index = Kata

--- Starter text for this kata's solution buffer: the user's template for the
--- language if they configured one, else the code Codewars seeded. Every site
--- that writes starter text goes through here, so `:CW reset` can never
--- disagree with what the file was first created with.
---@return string
function Kata:_starter_code()
    return require("codewars.templates").render(self.lang, self:_template_ctx())
end

--- Kata metadata a template function can branch on.
---@return table
function Kata:_template_ctx()
    return {
        lang = self.lang,
        slug = self.slug,
        name = self.name,
        rank = self.rank,
        tags = self.tags,
        -- Every starter reaches a buffer through here (new kata, reset, switch,
        -- template or not); self.setup_code stays as Codewars sent it.
        starter = require("codewars.indent").starter(self.lang, self.setup_code or ""),
    }
end

---@return string
function Kata:_buffer_text()
    return table.concat(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false), "\n")
end

--- Replace the solution buffer's contents.
---
--- Deliberately not ui_utils.buf_set_lines: that one leaves the buffer
--- unmodifiable, which is right for the read-only panels it was written for and
--- wrong for the buffer the user is about to type in.
---@param text string
function Kata:_set_code(text)
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, vim.split(text, "\n"))
end

--- Rewrite the open buffer through one of the template operations.
---
--- A single set_lines call, so the whole rewrite is one undo entry: `u` puts
--- the buffer back however it goes. Both operations refuse rather than guess
--- when the buffer no longer matches the template, and the reason is worth
--- surfacing — "nothing happened" on its own reads as a broken command.
---@param op "wrap"|"strip"
---@return boolean changed
function Kata:retemplate(op)
    if not (self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)) then
        return false
    end

    assert(op == "wrap" or op == "strip", "unknown template op: " .. tostring(op))
    local templates = require("codewars.templates")
    local apply = op == "wrap" and templates.wrap or templates.strip

    local before = self:_buffer_text()
    local text, reason = apply(self.lang, before, self:_template_ctx())
    if not text then
        log.info(reason)
        return false
    end

    self:_set_code(text)
    if self._file_name then
        require("codewars.unfinished").retemplated(self._file_name, before, text)
    end
    -- Forced: the rewrite moved the user's code, so wherever the cursor was
    -- describes a buffer that no longer exists. Both directions end up at the
    -- same question -- where is the code now -- and the buffer answers it.
    self:_cursor_to_end(true)
    return true
end

--- The file the user chose from a list of solution files, when there is one
--- to open in `lang`: it still exists, and is for this language -- a switch to
--- another language has its own file to open.
---@param lang table an entry from config.langs
---@return string?
function Kata:_picked_file_name(lang)
    local picked = self._picked_file
    if not picked or vim.fn.fnamemodify(picked, ":e") ~= lang.ft then return nil end
    if not config.storage.home:joinpath(picked):exists() then return nil end
    return picked
end

--- The solution file a kata opens when nothing says which: the one named
--- after its slug.
---@param lang table an entry from config.langs
---@return string
function Kata:_default_file_name(lang)
    local by_slug = ("%s.%s"):format(self.slug, lang.ft)
    -- Older versions named a kata opened by its id after the id. The kata has
    -- its slug by now, so look for that file too, or the work in it never
    -- shows and a fresh starter is seeded beside it.
    local by_id = self.kata_id and self.kata_id ~= self.slug and ("%s.%s"):format(self.kata_id, lang.ft)
    if by_id and not config.storage.home:joinpath(by_slug):exists()
        and config.storage.home:joinpath(by_id):exists() then
        return by_id
    end
    return by_slug
end

--- Point self.file at this kata's solution in self.lang, seeding the starter
--- when there is no file yet. Either way the starter goes on record, so that
--- :CW unfinished can tell a kata you are working in from one you only opened.
---@return boolean existed
function Kata:_open_file()
    local lang = utils.get_lang(self.lang)
    assert(lang, "Unsupported language: " .. self.lang)
    self._file_name = self:_picked_file_name(lang) or self:_default_file_name(lang)
    self.file = config.storage.home:joinpath(self._file_name)

    local unfinished = require("codewars.unfinished")
    if self.file:exists() then
        unfinished.opened(self._file_name, function() return self:_starter_code() end, self:_info())
        return true
    end
    local starter = self:_starter_code()
    self.file:write(starter, "w")
    unfinished.seeded(self._file_name, starter, self:_info())
    return false
end

--- What :CW unfinished shows for this kata: the catalogue does not hold
--- every kata, so the name and rank go on record with its starter.
---@return cw.KataInfo
function Kata:_info()
    return { name = self.name, rank_id = self.rank }
end

---@return string path, boolean existed
function Kata:path()
    local existed = self:_open_file()

    local templates = require("codewars.templates")
    if existed and templates.is_enabled() and templates.is_configured(self.lang) then
        -- Seeding is guarded so it can never overwrite work in progress, which
        -- means a configured template silently does nothing on a kata you have
        -- opened before. Say so, rather than letting it read as a broken feature.
        log.info(("%s already exists — :CW reset to apply your %s template."):format(self._file_name, self.lang))
    end

    return self.file:absolute(), existed
end

function Kata:create_buffer()
    local path, _ = self:path()

    -- Escaped: a storage.home with a space or a Vim metacharacter would
    -- otherwise open the wrong file, not the one just written.
    vim.cmd("$tabe " .. vim.fn.fnameescape(path))
    self.bufnr = vim.api.nvim_get_current_buf()
    self.winid = vim.api.nvim_get_current_win()
    ui_utils.win_set_winfixbuf(self.winid)

    self:_show_buffer()
end

--- Show self.bufnr, the solution file just opened, in the kata's window.
function Kata:_show_buffer()
    ui_utils.set_code_buffer(self.bufnr, self.lang, { buflisted = true })
    ui_utils.win_set_buf(self.winid, self.bufnr, true)
    self:_cursor_to_end()
end

--- Where the starter sits in THIS buffer, right now.
---
--- Deliberately not cached from the render that seeded the file. That value is
--- only produced on the first visit, and a language switch onto a file that
--- already exists never refreshes it -- so a cached position outlives the
--- buffer it described and then wins over looking. The buffer is the one thing
--- that is always current.
---@return cw.templates.Pos?
function Kata:_locate_starter()
    local ok, pos = pcall(function()
        return require("codewars.templates").locate(self.lang, self:_buffer_text(), self:_template_ctx())
    end)
    -- locate() declining is ordinary and stays quiet: editing your own
    -- preamble is enough to stop the buffer matching the template, and the
    -- cursor simply falls back. An error inside it is not ordinary, and
    -- collapsing the two into the same silence hides it.
    if not ok then
        log.debug("kata could not locate the starter: " .. tostring(pos))
        return nil
    end
    return pos
end

--- Put the cursor on the code the user came to write.
---
--- The top of a templated buffer is their own boilerplate, so landing on line 1
--- means scrolling past it every time.
---
--- A position something else already claimed is left alone: `$tabe` fires
--- BufReadPost, so a restore-last-position autocmd has already run, and
--- anything but {1, 0} is its claim. The exception is a claim inside the
--- template's preamble -- generated boilerplate, not somewhere chosen.
---
--- `force` skips that check, for callers that just rewrote the buffer and left
--- the old position describing one that no longer exists.
---@param force boolean?
function Kata:_cursor_to_end(force)
    if not (self.winid and vim.api.nvim_win_is_valid(self.winid)) then
        return
    end

    local ok, pos = pcall(vim.api.nvim_win_get_cursor, self.winid)
    if not ok then
        return
    end

    local target = self:_locate_starter()
    -- Testing the row alone would override a restore to {1, 12}, which is
    -- every bit as much a claim as one on another line.
    local claimed = pos[1] ~= 1 or pos[2] ~= 0
    local in_preamble = target
        and (pos[1] < target.start_row
            or (pos[1] == target.start_row and pos[2] < target.start_col))
    if not force and claimed and not in_preamble then
        return
    end

    local row, col
    if target then
        row, col = target.row, target.col
    else
        -- No template to measure against, so the code is the whole buffer.
        -- end_of applies the same rule the templated path uses: trailing blank
        -- lines are not the last thing the user wrote, and the column lands on
        -- a character rather than inside a multibyte one.
        row, col = require("codewars.templates").end_of(self:_buffer_text())
    end

    pcall(vim.api.nvim_win_set_cursor, self.winid, { row, col })
    self:_show_around_cursor()
end

--- Put the cursor back on the starter once the panels have taken their space.
---
--- Re-placed only when the starter can actually be found: on a buffer that no
--- longer matches the template there is nothing to aim at, and whatever
--- position it already had is better than a guess. The view is squared up
--- either way, since the resize is what moved it.
function Kata:_settle_cursor()
    if not (self.winid and vim.api.nvim_win_is_valid(self.winid)) then
        return
    end

    local target = self:_locate_starter()
    if target and target.row then
        pcall(vim.api.nvim_win_set_cursor, self.winid, { target.row, target.col })
    end
    self:_show_around_cursor()
end

--- Fill the panel with the lines leading up to the cursor.
---
--- Moving the cursor scrolls DOWN to reveal it, never back up. A rewrite that
--- shrinks the buffer -- `:CW template off` dropping a long preamble -- leaves
--- the window parked at a top line that is now near the end, so the panel
--- shows the last line or two of the file and nothing else.
function Kata:_show_around_cursor()
    if not (self.winid and vim.api.nvim_win_is_valid(self.winid)) then
        return
    end
    -- `zb` rather than `zz`: at the end of a buffer, centring would waste half
    -- the panel on the blank space past it.
    pcall(vim.api.nvim_win_call, self.winid, function()
        vim.cmd("normal! zb")
    end)
end

--- Give up on this mount: no window will ever exist, so drop the one-shot
--- continuation. Leaving it set matters — the callback captures the kata it
--- was going to replace, and this instance is held by the focus layer for
--- the rest of the session, so an unfired hook pins that whole object.
function Kata:_abandon_mount()
    self._on_mounted = nil
end

--- This kata is already open in a tab: there is one per kata and language,
--- and the runner and the rest of the plugin look the kata up by it, so a
--- second mount goes to that tab instead of opening another. A file picked
--- from a list is the one case where that can be a different file than the
--- user asked for -- `<slug>.py` open, `<id>.py` picked -- and then the tab
--- is not silently passed off as the pick.
---@param tabp integer
---@param open cw.ui.Kata? the instance open in that tab
function Kata:_go_to_open_tab(tabp, open)
    pcall(vim.api.nvim_set_current_tabpage, tabp)
    local lang = utils.get_lang(self.lang)
    local picked, open_file = self._picked_file, open and open._file_name
    if picked and open_file and lang and picked ~= open_file
        and vim.fn.fnamemodify(picked, ":e") == lang.ft then
        log.warn(("%s is already open in this kata's tab, and you picked %s. "
            .. "Close the open one to open the other."):format(open_file, picked))
    end
    self:_abandon_mount()
end

function Kata:mount()
    log.info(("Loading kata %s..."):format(self.slug))

    local kata_api = require("codewars.api.kata")
    kata_api.get(self.slug, function(kata_data, err)
        if err then
            if err.status == 404 then
                log.error(("Kata '%s' not found. Check the name or use the hex ID from the URL."):format(self.slug))
            else
                log.err(err)
            end
            self:_abandon_mount()
            return
        end

        if kata_data.slug and kata_data.slug ~= "" then
            self.slug = kata_data.slug
        end

        local tabp, open = utils.detect_duplicate_kata(self.slug, self.lang)
        if tabp then
            self:_go_to_open_tab(tabp, open)
            return
        end

        local cached = session_cache.get(self.slug, self.lang)
        if cached then
            self:apply_session(cached)
            vim.schedule(function()
                self:handle_mount()
            end)
            return
        end

        self.name = kata_data.name
        self.description_text = kata_data.description
        self.tags = kata_data.tags
        self.supported_languages = kata_data.languages or {}
        self.total_completed = kata_data.totalCompleted
        self.total_attempts = kata_data.totalAttempts
        if kata_data.rank then
            self.rank = kata_data.rank.id
        end

        if kata_data.languages and #kata_data.languages > 0 and not vim.tbl_contains(kata_data.languages, self.lang) then
            if self._lang_explicit then
                log.error(("Language '%s' is not available for this kata. Available: %s"):format(
                    self.lang, table.concat(kata_data.languages, ", ")))
                self:_abandon_mount()
                return
            end
            local fallback = kata_data.languages[1]
            log.info(("Using %s ('%s' not available for this kata)"):format(fallback, self.lang))
            self.lang = fallback

            -- The duplicate check above ran with the REQUESTED language; the
            -- kata may already be open in the one we just fell back to.
            local dup, dup_open = utils.detect_duplicate_kata(self.slug, self.lang)
            if dup then
                self:_go_to_open_tab(dup, dup_open)
                return
            end
        end

        -- Train page requires the hex kata ID, not the readable slug
        self.kata_id = kata_data.id
        local train_api = require("codewars.api.train")
        train_api.start(self.kata_id, self.lang, function(session, train_err)
            if train_err then
                -- If auth error, clear session cache so next attempt gets a fresh session
                if train_err.auth then
                    session_cache.delete(self.slug, self.lang)
                end
                self:_abandon_mount()
                return log.err(train_err)
            end

            self.project_id = session.projectId or ""
            self.solution_id = session.solutionId or ""
            self.setup_code = session.setup or ""
            self.example_fixture = session.exampleFixture or ""
            self.fixture = session.fixture or ""
            self.package = session["package"] or ""
            self.test_framework = session.testFramework or "cw-2"
            self.language_version = session.activeVersion

            self:save_session()

            vim.schedule(function()
                self:handle_mount()
            end)
        end)
    end)

    return self
end

---@param data table
function Kata:apply_session(data)
    self.name = data.name or self.slug
    self.description_text = data.description or ""
    self.tags = data.tags or {}
    self.rank = data.rank
    self.kata_id = data.kata_id or self.slug
    self.project_id = data.project_id or ""
    self.solution_id = data.solutionId or ""
    self.setup_code = data.setup or ""
    self.example_fixture = data.exampleFixture or ""
    self.fixture = data.fixture or ""
    self.package = data["package"] or ""
    self.test_framework = data.testFramework or "cw-2"
    self.language_version = data.activeVersion
    self.supported_languages = data.supported_languages or {}
    self.total_completed = data.total_completed
    self.total_attempts = data.total_attempts
end

function Kata:save_session()
    session_cache.save(self.slug, self.lang, {
        name = self.name,
        description = self.description_text,
        tags = self.tags,
        rank = self.rank,
        kata_id = self.kata_id,
        project_id = self.project_id,
        solutionId = self.solution_id,
        setup = self.setup_code,
        exampleFixture = self.example_fixture,
        fixture = self.fixture,
        ["package"] = self.package,
        testFramework = self.test_framework,
        activeVersion = self.language_version,
        supported_languages = self.supported_languages,
        total_completed = self.total_completed,
        total_attempts = self.total_attempts,
    })
end

function Kata:handle_mount()
    self:create_buffer()

    self.description = Description:new(self)
    self.description:mount()

    self.testcase_split = TestcaseSplit:new(self)
    if config.user.testcase.open_on_enter then
        self.testcase_split:mount()
        if self.example_fixture and self.example_fixture ~= "" then
            self.testcase_split:populate(self.example_fixture)
        end
    else
        self.testcase_split.original_fixture = self.example_fixture or ""
    end

    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_set_current_win(self.winid)
    end

    self.console = Console(self)

    table.insert(_Cw_state.katas, self)

    self:autocmds()

    -- Optional one-shot callback for callers that must act only once this
    -- kata is really on screen. mount() is async and can bail early (404,
    -- auth failure, or a jump to an already-open duplicate tab), so
    -- "mount() returned" is NOT the same as "a window exists". :CW focus
    -- skip relies on this to close the kata it replaces only after the
    -- replacement is visible.
    if self._on_mounted then
        local on_mounted = self._on_mounted
        self._on_mounted = nil
        local ok, err = pcall(on_mounted, self)
        if not ok then log.debug("kata on_mounted hook failed: " .. tostring(err)) end
    end

    -- Last, and scheduled: create_buffer placed the cursor against a
    -- full-height window, and everything since -- both splits, the console
    -- layout, the autocmds, the caller's own hook -- has taken space from it
    -- or moved through it. A position measured before all that leaves the
    -- panel scrolled somewhere the starter is not.
    vim.schedule(function()
        self:_settle_cursor()
    end)

    require("codewars.cache.recent").record(self)
    utils.exec_hooks("kata_enter", self)
end

function Kata:autocmds()
    -- Keyed by WINDOW, not slug: the same kata may be open in a second
    -- language (detect_duplicate_kata only blocks slug+lang), and a
    -- slug-keyed group with clear=true let the second mount wipe the
    -- first's WinClosed handler, so that kata was never cleaned up.
    local group = vim.api.nvim_create_augroup("codewars_kata_win_" .. tostring(self.winid), { clear = true })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(self.winid),
        callback = function()
            self:_unmount()
        end,
    })
end

--- Write a solution buffer to its file if it has unsaved edits. The
--- buffers are force-deleted on close (the tab is gone, there is nothing
--- to prompt in), and the file is the plugin's own storage, so saving is
--- always the right call: closing a kata must never lose typed code.
---@param bufnr integer
---@return boolean saved
local function flush_if_modified(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return false end
    if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then return false end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" or vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then return false end
    local ok = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent noautocmd write")
    end)
    if ok then
        log.info(("Saved unsaved edits to %s"):format(vim.fn.fnamemodify(name, ":t")))
    end
    return ok
end

function Kata:_unmount()
    if vim.v.dying ~= 0 then
        return
    end

    vim.schedule(function()
        if self.console then
            self.console:unmount()
        end
        if self.testcase_split then
            self.testcase_split:unmount()
        end
        if self.description then
            self.description:unmount()
        end

        -- The current solution buffer plus every buffer an earlier language
        -- switch left behind (they were only unlisted, so they leaked for
        -- the rest of the session).
        local bufs = { self.bufnr }
        vim.list_extend(bufs, self._old_bufnrs or {})
        for _, b in ipairs(bufs) do
            if b and vim.api.nvim_buf_is_valid(b) then
                local modified = vim.api.nvim_get_option_value("modified", { buf = b })
                if modified and not flush_if_modified(b) then
                    -- The write failed (read-only file, unwritable storage,
                    -- full disk): deleting now would be the silent loss this
                    -- exists to prevent. Keep the buffer, listed, and say so.
                    pcall(vim.api.nvim_set_option_value, "buflisted", true, { buf = b })
                    log.warn(("Could not save %s — the buffer is kept so your edits are not lost; :w it by hand.")
                        :format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t")))
                else
                    pcall(vim.api.nvim_buf_delete, b, { force = true, unload = false })
                end
            end
        end
        self._old_bufnrs = nil

        _Cw_state.katas = vim.tbl_filter(function(k)
            return k ~= self and k.bufnr ~= self.bufnr
        end, _Cw_state.katas)
    end)
end

function Kata:unmount()
    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
        vim.api.nvim_win_close(self.winid, true)
    end
end

function Kata:reset_code()
    if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
        local starter = self:_starter_code()
        self:_set_code(starter)
        -- A fresh start: this starter, not the first one, is what counts as
        -- untouched now.
        if self._file_name then
            require("codewars.unfinished").seeded(self._file_name, starter, self:_info())
        end
        -- Forced: the rewrite moved the user's code out from under wherever
        -- they were standing, so the old position is not a claim on anything.
        self:_cursor_to_end(true)
        log.info("Code reset to template")
    end
end

--- Change language in-place without closing the tab.
--- Fetches a new training session, swaps the buffer content and filetype.
---@param self cw.ui.Kata
---@param new_lang string
Kata.change_lang = vim.schedule_wrap(function(self, new_lang)
    if new_lang == self.lang then
        return log.info("Already using " .. new_lang)
    end

    local prev_bufnr = self.bufnr

    -- Generation counter: two switches in flight resolve in network order,
    -- and without this the EARLIER reply landing last overwrote the later
    -- choice (lang, session ids and the window's buffer). Only the newest
    -- request may apply; and none may apply to a workspace that closed
    -- while it was waiting.
    self._lang_gen = (self._lang_gen or 0) + 1
    local gen = self._lang_gen

    log.info(("Switching to %s..."):format(new_lang))

    local train_api = require("codewars.api.train")
    train_api.start(self.kata_id, new_lang, function(session, err)
        if err then
            return log.err(err)
        end

        vim.schedule(function()
            if gen ~= self._lang_gen then
                return log.debug(("stale language switch to %s ignored"):format(new_lang))
            end
            if not (self.winid and vim.api.nvim_win_is_valid(self.winid)) then
                return log.debug("language switch arrived after the kata closed")
            end

            -- Everything the switch rewrites, so a failure part-way can put
            -- the whole previous session back, not just lang and bufnr:
            -- half a session (old buffer, new solution id) would attempt
            -- against the wrong trainer session.
            local SESSION_FIELDS = {
                "lang", "bufnr", "project_id", "solution_id", "setup_code", "example_fixture",
                "fixture", "package", "test_framework", "language_version", "last_attempt_success",
                "finalized", "file", "_file_name", "_notify_pending", "_submit_queued",
            }
            local before = {}
            for _, k in ipairs(SESSION_FIELDS) do before[k] = self[k] end

            local ok, change_err = pcall(function()
                self.lang = new_lang
                self.project_id = session.projectId or self.project_id
                self.solution_id = session.solutionId or ""
                self.setup_code = session.setup or ""
                self.example_fixture = session.exampleFixture or ""
                self.fixture = session.fixture or ""
                self.package = session["package"] or ""
                self.test_framework = session.testFramework or "cw-2"
                self.language_version = session.activeVersion
                self.last_attempt_success = false
                self.finalized = false
                -- A notify still in flight, and a submit held for one, belong
                -- to the old session: neither may lock or submit this one.
                self._notify_pending = 0
                self._submit_queued = nil

                self:_open_file()
                require("codewars.cache.recent").record(self)

                local path = self.file:absolute()
                self.bufnr = vim.fn.bufadd(path)
                assert(self.bufnr ~= 0, "Failed to create buffer " .. path)
                vim.fn.bufload(self.bufnr)

                vim.api.nvim_set_option_value("buflisted", false, { buf = prev_bufnr })
                -- Remembered so _unmount can flush and delete it: an unlisted
                -- buffer nobody tracks leaks for the rest of the session.
                self._old_bufnrs = self._old_bufnrs or {}
                if prev_bufnr ~= self.bufnr then table.insert(self._old_bufnrs, prev_bufnr) end
                self:_show_buffer()

                if self.testcase_split then
                    self.testcase_split:populate(self.example_fixture)
                end
                if self.description then
                    self.description:populate()
                end

                self:save_session()
                log.info(("Switched to %s"):format(new_lang))
            end)

            if not ok then
                log.error("Failed to change language\n" .. tostring(change_err))
                -- The target buffer may already exist; track it so unmount
                -- deletes it instead of leaving a listed stray.
                local target_bufnr = self.bufnr
                for _, k in ipairs(SESSION_FIELDS) do self[k] = before[k] end
                if target_bufnr and target_bufnr ~= prev_bufnr and vim.api.nvim_buf_is_valid(target_bufnr) then
                    self._old_bufnrs = self._old_bufnrs or {}
                    table.insert(self._old_bufnrs, target_bufnr)
                    pcall(vim.api.nvim_set_option_value, "buflisted", false, { buf = target_bufnr })
                end
                if prev_bufnr and vim.api.nvim_buf_is_valid(prev_bufnr) then
                    pcall(ui_utils.buf_set_opts, prev_bufnr, { buflisted = true })
                    if self.winid and vim.api.nvim_win_is_valid(self.winid) then
                        pcall(ui_utils.win_set_buf, self.winid, prev_bufnr, true)
                    end
                end
            end
        end)
    end)
end)

---@class cw.ui.KataOpts
---@field file string? a solution file in storage.home to open, where the kata has more than one

---@param slug string
---@param lang? string
---@param opts? cw.ui.KataOpts
---@return cw.ui.Kata
function Kata:new(slug, lang, opts)
    local obj = setmetatable({}, self)
    obj.slug = slug
    obj.lang = lang or config.lang
    obj._picked_file = opts and opts.file or nil
    obj.last_attempt_success = false
    obj.finalized = false
    return obj
end

return Kata
