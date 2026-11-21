-- Who is signed in, for the code that needs the account before the menu has
-- ever run: config.user.username is only ever filled in by detection, which
-- the menu used to be the only thing to start. Detection itself -- the cached
-- identity bound to the live cookie, the /dashboard scrape, the guard against
-- a reply for a session that has since changed -- is the menu's, shared.
describe("identity", function()
    local config = {
        user = { username = "", lang = "python" },
        lang = "python",
        lang_persisted = false,
    }
    package.loaded["codewars.config"] = config
    package.loaded["codewars.logger"] = setmetatable({}, {
        __index = function() return function() end end,
    })

    package.loaded["codewars.identity"] = nil
    local identity = require("codewars.identity")

    local cookie, fp, stored, scrapes, pending, scraped

    before_each(function()
        config.user.username, config.user.lang, config.lang, config.lang_persisted = "", "python", "python", false
        cookie, fp, stored, scrapes, pending = { session_id = "alice" }, "alice-session", nil, 0, nil
        scraped = { username = "prosk", current_language = "rust" }

        package.loaded["codewars.cache.cookie"] = { get = function() return cookie end }
        local profile_stub
        profile_stub = {
            fingerprint = function() return fp end,
            get = function()
                if stored and stored.fp == fp then return vim.deepcopy(stored) end
            end,
            save = function(d)
                stored = vim.tbl_extend("force", vim.deepcopy(d), { fp = fp })
                return true
            end,
            update = function(f) return profile_stub.save(vim.tbl_extend("force", profile_stub.get() or {}, f)) end,
        }
        package.loaded["codewars.cache.profile"] = profile_stub
        package.loaded["codewars.api.user"] = {
            -- Answers when the test says so, to leave room for the session to change.
            get_current = function(cb)
                scrapes = scrapes + 1
                pending = function(profile, err) cb(profile, err) end
            end,
        }
    end)

    after_each(function()
        package.loaded["codewars.cache.cookie"] = nil
        package.loaded["codewars.cache.profile"] = nil
        package.loaded["codewars.api.user"] = nil
    end)

    local function ensure()
        local result = {}
        identity.ensure(function(username, err)
            result.username, result.err, result.called = username, err, true
        end)
        return result
    end

    it("answers at once with the name it already has", function()
        config.user.username = "prosk"
        local result = ensure()
        assert.are.equal("prosk", result.username)
        assert.are.equal(0, scrapes)
    end)

    it("is signed out, and says so, with no cookie saved", function()
        cookie = nil
        local result = ensure()
        assert.is_true(result.called)
        assert.is_nil(result.username)
        assert.is_true(result.err.signed_out)
        assert.are.equal(0, scrapes, "asked the dashboard without a session")
        assert.are.equal("", config.user.username)
    end)

    it("takes this session's cached identity without asking the dashboard", function()
        stored = { username = "prosk", lang = "rust", fp = fp }
        local result = ensure()
        assert.are.equal("prosk", result.username)
        assert.are.equal("prosk", config.user.username)
        assert.are.equal("rust", config.lang, "the detected language was not applied, as the menu applies it")
        assert.are.equal(0, scrapes)
    end)

    it("reads the name off the dashboard when none is cached, and keeps it", function()
        local result = ensure()
        assert.is_nil(result.called, "answered before the dashboard did")
        pending(scraped)
        assert.are.equal("prosk", result.username)
        assert.are.equal("prosk", config.user.username)
        assert.are.equal("rust", config.lang)
        assert.are.equal("prosk", stored.username)
    end)

    it("does not make a name up when the dashboard bounced the session", function()
        local result = ensure()
        pending(nil, { auth = true, msg = "session expired" })
        assert.is_nil(result.username)
        assert.is_true(result.err.auth)
        assert.are.equal("", config.user.username)
    end)

    it("does not make a name up when the dashboard could not be read", function()
        local result = ensure()
        pending(nil, { msg = "network down" })
        assert.is_nil(result.username)
        assert.are.equal("network down", result.err.msg)
        assert.are.equal("", config.user.username)

        result = ensure()
        pending({ current_language = "rust" })
        assert.is_nil(result.username)
        assert.is_not_nil(result.err, "no name and no reason")
        assert.are.equal("", config.user.username)
    end)

    it("drops a reply for a session that changed while it was out", function()
        local result = ensure()
        fp = "bob-session"
        pending(scraped)
        assert.is_nil(result.username)
        assert.is_not_nil(result.err)
        assert.are.equal("", config.user.username, "adopted a name for a session that is gone")
        assert.is_nil(stored)
    end)
end)
