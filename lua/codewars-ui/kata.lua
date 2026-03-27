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

---@return string path, boolean existed
function Kata:path()
    local lang = utils.get_lang(self.lang)
    assert(lang, "Unsupported language: " .. self.lang)
    local fn = ("%s.%s"):format(self.slug, lang.ft)

    self.file = config.storage.home:joinpath(fn)
    local existed = self.file:exists()

    if not existed then
        self.file:write(self.setup_code or "", "w")
    end

    return self.file:absolute(), existed
end

function Kata:create_buffer()
    local path, _ = self:path()

    vim.cmd("$tabe " .. path)
    self.bufnr = vim.api.nvim_get_current_buf()
    self.winid = vim.api.nvim_get_current_win()
    ui_utils.win_set_winfixbuf(self.winid)

    ui_utils.buf_set_opts(self.bufnr, { buflisted = true })
    ui_utils.win_set_buf(self.winid, self.bufnr, true)
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
            return
        end

        if kata_data.slug and kata_data.slug ~= "" then
            self.slug = kata_data.slug
        end

        local tabp = utils.detect_duplicate_kata(self.slug, self.lang)
        if tabp then
            pcall(vim.api.nvim_set_current_tabpage, tabp)
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
                return
            end
            local fallback = kata_data.languages[1]
            log.info(("Using %s ('%s' not available for this kata)"):format(fallback, self.lang))
            self.lang = fallback
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
    utils.exec_hooks("kata_enter", self)
end

function Kata:autocmds()
    local group = vim.api.nvim_create_augroup("codewars_kata_" .. self.slug, { clear = true })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(self.winid),
        callback = function()
            self:_unmount()
        end,
    })
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

        if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
            vim.api.nvim_buf_delete(self.bufnr, { force = true, unload = false })
        end

        _Cw_state.katas = vim.tbl_filter(function(k)
            return k.bufnr ~= self.bufnr
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
        local lines = vim.split(self.setup_code or "", "\n")
        vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
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

    local prev_lang = self.lang
    local prev_bufnr = self.bufnr

    log.info(("Switching to %s..."):format(new_lang))

    local train_api = require("codewars.api.train")
    train_api.start(self.kata_id, new_lang, function(session, err)
        if err then
            return log.err(err)
        end

        vim.schedule(function()
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

                local lang_info = utils.get_lang(new_lang)
                assert(lang_info, "Unsupported language: " .. new_lang)
                local fn = ("%s.%s"):format(self.slug, lang_info.ft)
                self.file = config.storage.home:joinpath(fn)

                if not self.file:exists() then
                    self.file:write(self.setup_code, "w")
                end

                local path = self.file:absolute()
                self.bufnr = vim.fn.bufadd(path)
                assert(self.bufnr ~= 0, "Failed to create buffer " .. path)
                vim.fn.bufload(self.bufnr)

                vim.api.nvim_set_option_value("buflisted", false, { buf = prev_bufnr })
                ui_utils.buf_set_opts(self.bufnr, { buflisted = true })
                ui_utils.win_set_buf(self.winid, self.bufnr, true)

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
                self.lang = prev_lang
                self.bufnr = prev_bufnr
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
