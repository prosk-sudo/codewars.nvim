-- Exercises the REAL lua/codewars-ui/kata.lua mount lifecycle.
--
-- focus_command_spec replaces this module with a stub, so the production
-- early-return paths are invisible to it. The thing under test here is
-- Kata:_abandon_mount(): mount() can bail four different ways, and each one
-- must drop the one-shot _on_mounted continuation. An unfired hook captures
-- the kata it was going to replace, and the instance is held by the focus
-- layer for the rest of the session, so a leaked hook pins a whole kata.
describe("Kata mount lifecycle", function()
    package.loaded["codewars.config"] = {
        user = { keys = { toggle = { "q" } }, testcase = { open_on_enter = false } },
        lang = "python",
    }
    package.loaded["codewars.logger"] = {
        info = function() end,
        warn = function() end,
        error = function() end,
        err = function() end,
        debug = function() end,
    }
    -- UI deps are only reached past handle_mount; stub them so requiring the
    -- module never touches nui or a real window.
    package.loaded["codewars-ui.split.description"] = { new = function() return {} end }
    package.loaded["codewars-ui.split.testcase"] = { new = function() return {} end }
    package.loaded["codewars-ui.layout.console"] = function() return {} end
    package.loaded["codewars-ui.utils"] = {
        buf_set_opts = function() end,
        win_set_opts = function() end,
        win_set_buf = function() end,
        win_set_winfixbuf = function() end,
        buf_set_lines = function() end,
    }

    local duplicate_tabpage = nil
    package.loaded["codewars.utils"] = {
        get_lang = function(slug) return { slug = slug, ft = "py" } end,
        detect_duplicate_kata = function() return duplicate_tabpage end,
        exec_hooks = function() end,
    }

    package.loaded["codewars.cache.session"] = {
        get = function() return nil end,
        save = function() end,
        delete = function() end,
    }

    -- Controllable API layer: each test scripts one early return.
    local kata_response = {}
    package.loaded["codewars.api.kata"] = {
        get = function(_, cb) cb(kata_response.data, kata_response.err) end,
    }
    local train_response = {}
    package.loaded["codewars.api.train"] = {
        start = function(_, _, cb) cb(train_response.session, train_response.err) end,
    }

    package.loaded["codewars-ui.kata"] = nil
    local Kata = require("codewars-ui.kata")

    before_each(function()
        duplicate_tabpage = nil
        kata_response = { data = { id = "abc", slug = "valid-braces", languages = { "python" } } }
        train_response = { err = { msg = "train failed" } }
    end)

    --- A kata with a continuation armed, as the focus layer arms it.
    local function armed_kata(lang)
        local k = Kata:new("valid-braces", lang or "python")
        local fired = { count = 0 }
        k._on_mounted = function() fired.count = fired.count + 1 end
        return k, fired
    end

    it("drops the continuation when the kata fetch fails (404)", function()
        kata_response = { err = { status = 404 } }
        local k, fired = armed_kata()
        k:mount()
        assert.is_nil(k._on_mounted)
        assert.are.equal(0, fired.count)
    end)

    it("drops the continuation on a non-404 fetch error", function()
        kata_response = { err = { msg = "network down" } }
        local k, fired = armed_kata()
        k:mount()
        assert.is_nil(k._on_mounted)
        assert.are.equal(0, fired.count)
    end)

    it("drops the continuation when it jumps to an already-open duplicate tab", function()
        duplicate_tabpage = 7
        local k, fired = armed_kata()
        k:mount()
        assert.is_nil(k._on_mounted)
        assert.are.equal(0, fired.count)
    end)

    it("drops the continuation when the language is unavailable and explicit", function()
        kata_response = { data = { id = "abc", slug = "valid-braces", languages = { "go" } } }
        local k, fired = armed_kata("python")
        k._lang_explicit = true
        k:mount()
        assert.is_nil(k._on_mounted)
        assert.are.equal(0, fired.count)
    end)

    it("drops the continuation when starting the training session fails", function()
        train_response = { err = { msg = "session refused" } }
        local k, fired = armed_kata()
        k:mount()
        assert.is_nil(k._on_mounted)
        assert.are.equal(0, fired.count)
    end)

    it("drops the continuation on an auth failure, after clearing the session cache", function()
        local deleted = 0
        package.loaded["codewars.cache.session"].delete = function() deleted = deleted + 1 end
        train_response = { err = { auth = true, msg = "session expired" } }
        local k, fired = armed_kata()
        k:mount()
        assert.are.equal(1, deleted)
        assert.is_nil(k._on_mounted)
        assert.are.equal(0, fired.count)
    end)

    it("_abandon_mount is idempotent", function()
        local k = armed_kata()
        k:_abandon_mount()
        k:_abandon_mount()
        assert.is_nil(k._on_mounted)
    end)

    it("a kata with no continuation mounts through the same paths without error", function()
        kata_response = { err = { status = 404 } }
        local k = Kata:new("valid-braces", "python")
        assert.has_no.errors(function() k:mount() end)
    end)
end)
