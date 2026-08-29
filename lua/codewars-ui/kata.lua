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
        starter = self.setup_code or "",
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

    local text, reason = apply(self.lang, self:_buffer_text(), self:_template_ctx())
    if not text then
        log.info(reason)
        return false
    end

    self:_set_code(text)
    -- Forced: the rewrite moved the user's code, so wherever the cursor was
    -- describes a buffer that no longer exists. Both directions end up at the
    -- same question -- where is the code now -- and the buffer answers it.
    self:_cursor_to_end(true)
    return true
end

---@return string path, boolean existed
function Kata:path()
    local lang = utils.get_lang(self.lang)
    assert(lang, "Unsupported language: " .. self.lang)
    local fn = ("%s.%s"):format(self.slug, lang.ft)

    self.file = config.storage.home:joinpath(fn)
    local existed = self.file:exists()

    local templates = require("codewars.templates")
    if not existed then
        self.file:write(self:_starter_code(), "w")
    elseif templates.is_enabled() and templates.is_configured(self.lang) then
        -- Seeding is guarded so it can never overwrite work in progress, which
        -- means a configured template silently does nothing on a kata you have
        -- opened before. Say so, rather than letting it read as a broken feature.
        log.info(("%s already exists — :CW reset to apply your %s template."):format(fn, self.lang))
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

    ui_utils.buf_set_opts(self.bufnr, { buflisted = true })
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

        local tabp = utils.detect_duplicate_kata(self.slug, self.lang)
        if tabp then
            pcall(vim.api.nvim_set_current_tabpage, tabp)
            self:_abandon_mount()
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
            local dup = utils.detect_duplicate_kata(self.slug, self.lang)
            if dup then
                pcall(vim.api.nvim_set_current_tabpage, dup)
                self:_abandon_mount()
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
        self:_set_code(self:_starter_code())
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
                "finalized", "file",
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
                -- Any notify still in flight belongs to the old session; it
                -- must not keep submit locked for this one.
                self._notify_pending = 0

                local lang_info = utils.get_lang(new_lang)
                assert(lang_info, "Unsupported language: " .. new_lang)
                local fn = ("%s.%s"):format(self.slug, lang_info.ft)
                self.file = config.storage.home:joinpath(fn)

                if not self.file:exists() then
                    self.file:write(self:_starter_code(), "w")
                end

                local path = self.file:absolute()
                self.bufnr = vim.fn.bufadd(path)
                assert(self.bufnr ~= 0, "Failed to create buffer " .. path)
                vim.fn.bufload(self.bufnr)

                vim.api.nvim_set_option_value("buflisted", false, { buf = prev_bufnr })
                -- Remembered so _unmount can flush and delete it: an unlisted
                -- buffer nobody tracks leaks for the rest of the session.
                self._old_bufnrs = self._old_bufnrs or {}
                if prev_bufnr ~= self.bufnr then table.insert(self._old_bufnrs, prev_bufnr) end
                ui_utils.buf_set_opts(self.bufnr, { buflisted = true })
                ui_utils.win_set_buf(self.winid, self.bufnr, true)
                self:_cursor_to_end()

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

---@param slug string
---@param lang? string
---@return cw.ui.Kata
function Kata:new(slug, lang)
    local obj = setmetatable({}, self)
    obj.slug = slug
    obj.lang = lang or config.lang
    obj.last_attempt_success = false
    obj.finalized = false
    return obj
end

return Kata
