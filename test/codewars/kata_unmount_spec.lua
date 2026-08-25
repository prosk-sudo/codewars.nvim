-- The close path of the REAL codewars-ui/kata.lua. The review found four
-- ways it lost work or leaked: a slug-keyed WinClosed augroup that a
-- second-language mount wiped, a force-delete of the solution buffer with
-- unsaved edits, previous-language buffers left behind by change_lang,
-- and a stale change_lang reply overwriting a later choice.
describe("Kata close lifecycle", function()
    local P = require("plenary.path")
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")

    package.loaded["codewars.config"] = {
        user = { keys = { toggle = { "q" } }, testcase = { open_on_enter = false }, templates = { solution = {} } },
        lang = "python",
        langs = require("codewars.config.langs"),
        storage = { home = P:new(tmp) },
    }
    package.loaded["codewars.logger"] = {
        info = function() end, warn = function() end, error = function() end,
        err = function() end, debug = function() end,
    }
    package.loaded["codewars.cache.session"] = { get = function() end, save = function() end, delete = function() end }

    -- Scripted train.start: callbacks are captured so a test can fire them
    -- in any order.
    local pending = {}
    package.loaded["codewars.api.train"] = {
        start = function(_, lang, cb) pending[#pending + 1] = { lang = lang, cb = cb } end,
    }

    package.loaded["codewars-ui.kata"] = nil
    local Kata = require("codewars-ui.kata")
    _Cw_state = _Cw_state or {}
    _Cw_state.katas = _Cw_state.katas or {}

    local n = 0
    --- A kata with a real file-backed solution buffer in its own tab.
    local function open(lang)
        n = n + 1
        local kata = Kata:new("close-kata-" .. n, lang or "python")
        kata.kata_id = "kid" .. n
        kata.setup_code = "def f(x):\n    return x"
        kata:create_buffer()
        kata:autocmds()
        table.insert(_Cw_state.katas, kata)
        return kata
    end

    local function wait_gone(bufnr)
        vim.wait(500, function() return not vim.api.nvim_buf_is_valid(bufnr) end)
    end

    before_each(function() pending = {} end)

    -- change_lang is schedule-wrapped: wait for its train.start to land.
    local function switch(kata, lang)
        local want = #pending + 1
        kata:change_lang(lang)
        vim.wait(500, function() return #pending >= want end)
        assert.are.equal(want, #pending, "change_lang never reached train.start")
    end

    it("keys the cleanup augroup by window, so a second language keeps the first's handler", function()
        local a = open("python")
        local b = open("ruby")
        local function handlers(k)
            return #vim.api.nvim_get_autocmds({ event = "WinClosed", pattern = tostring(k.winid) })
        end
        assert.are.equal(1, handlers(a), "first kata lost its WinClosed handler")
        assert.are.equal(1, handlers(b))
        a:unmount(); b:unmount()
        wait_gone(a.bufnr); wait_gone(b.bufnr)
    end)

    it("writes unsaved solution edits to the file before removing the buffer", function()
        local kata = open()
        local path = kata.file:absolute()
        vim.api.nvim_buf_set_lines(kata.bufnr, 0, -1, false, { "def f(x):", "    return x * 2  # typed, never :w'd" })
        assert.is_true(vim.bo[kata.bufnr].modified)
        local buf = kata.bufnr
        kata:unmount()
        wait_gone(buf)
        assert.is_false(vim.api.nvim_buf_is_valid(buf))
        assert.truthy(table.concat(vim.fn.readfile(path), "\n"):find("return x %* 2"))
    end)

    it("removes the buffers earlier language switches left behind", function()
        local kata = open("python")
        local first = kata.bufnr
        switch(kata,"ruby")
        pending[1].cb({ solutionId = "s2", projectId = "p" })
        vim.wait(200, function() return kata.bufnr ~= first end)
        assert.are_not.equal(first, kata.bufnr)
        assert.is_true(vim.api.nvim_buf_is_valid(first), "old buffer should linger until close")
        local second = kata.bufnr
        kata:unmount()
        wait_gone(second)
        vim.wait(200, function() return not vim.api.nvim_buf_is_valid(first) end)
        assert.is_false(vim.api.nvim_buf_is_valid(first), "old language buffer leaked")
    end)

    it("ignores a stale language reply that lands after a newer choice", function()
        local kata = open("python")
        switch(kata,"go")
        switch(kata,"ruby")
        assert.are.equal(2, #pending)
        -- ruby answers first, then the OLDER go request.
        pending[2].cb({ solutionId = "ruby-sol", projectId = "p" })
        vim.wait(200, function() return kata.lang == "ruby" end)
        pending[1].cb({ solutionId = "go-sol", projectId = "p" })
        vim.wait(100)
        assert.are.equal("ruby", kata.lang)
        assert.are.equal("ruby-sol", kata.solution_id)
        local buf = kata.bufnr
        kata:unmount()
        wait_gone(buf)
    end)

    it("drops a language reply that arrives after the kata closed", function()
        local kata = open("python")
        switch(kata,"go")
        local buf = kata.bufnr
        kata:unmount()
        wait_gone(buf)
        local ok = pcall(pending[1].cb, { solutionId = "go-sol", projectId = "p" })
        vim.wait(100)
        assert.is_true(ok)
        assert.are.equal("python", kata.lang)
    end)
end)
