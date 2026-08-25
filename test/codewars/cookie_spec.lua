-- The solutions cache carries the signed-in user's own votes; keeping it
-- across a cookie change let a stale `voted` flag turn the next vote into
-- a DELETE of a vote the new account never cast.
describe("Cookie identity change", function()
    local Path = require("plenary.path")
    local real_utils = package.loaded["codewars.cache.utils"]
    local Cookie, solutions

    before_each(function()
        -- Point the cookie file at a scratch path so the real session is
        -- never touched.
        package.loaded["codewars.cache.utils"] = vim.tbl_extend("force", real_utils or {}, {
            cache_file = function() return Path:new(vim.fn.tempname()) end,
        })
        package.loaded["codewars.cache.cookie"] = nil
        Cookie = require("codewars.cache.cookie")
        solutions = require("codewars.api.solutions")
        solutions._cache["kid/python"] = { at = os.time(), items = {} }
    end)
    after_each(function()
        package.loaded["codewars.cache.utils"] = real_utils
        package.loaded["codewars.cache.cookie"] = nil
        solutions.invalidate()
    end)

    it("setting a new cookie drops the solutions cache", function()
        assert.is_nil(Cookie.set("CSRF-TOKEN=abc; _session_id=xyz"))
        assert.is_nil(solutions._cache["kid/python"])
    end)

    it("signing out drops the solutions cache", function()
        Cookie.delete()
        assert.is_nil(solutions._cache["kid/python"])
    end)

    -- The review enumerated what else survived an account switch when only
    -- the solutions cache was dropped: the completed list (Bob shown as
    -- having solved Alice's kata, trainer dequeuing them), the per-kata
    -- session ids (Bob's attempt run against Alice's solution id), the
    -- detected username (menu still "Signed in as: alice"), the picker's
    -- memoised completed set, and the remembered focus kata.
    describe("drops every identity-scoped cache", function()
        local dir = vim.fn.tempname()
        local completed, session, config, cmd

        before_each(function()
            vim.fn.mkdir(dir, "p")
            -- Route every cache file into the scratch dir. Load the real
            -- module first: the outer real_utils is nil when nothing had
            -- required cache.utils before this spec ran.
            package.loaded["codewars.cache.utils"] = nil
            local real = require("codewars.cache.utils")
            package.loaded["codewars.cache.utils"] = vim.tbl_extend("force", real, {
                cache_file = function(name) return Path:new(dir .. "/" .. name) end,
            })
            for _, m in ipairs({ "codewars.cache.cookie", "codewars.cache.completed", "codewars.cache.session" }) do
                package.loaded[m] = nil
            end
            Cookie = require("codewars.cache.cookie")
            completed = require("codewars.cache.completed")
            session = require("codewars.cache.session")
            config = require("codewars.config")
            cmd = require("codewars.command")

            completed.save({ { id = "k1", slug = "k1" } })
            completed.save_details({ k1 = { rank = -8 } })
            session.save("some-kata", "python", { solutionId = "alice-sol", projectId = "alice-proj" })
            config.user.username = "alice"
        end)

        -- Put the real modules back so later specs do not inherit the
        -- scratch-dir cache_file stub through package.loaded.
        after_each(function()
            for _, m in ipairs({ "codewars.cache.utils", "codewars.cache.cookie", "codewars.cache.completed", "codewars.cache.session" }) do
                package.loaded[m] = nil
            end
        end)

        it("on a new cookie", function()
            -- forget_focus is spied rather than observed: populating the
            -- focus record needs the trainer + kata stubs that
            -- focus_command_spec owns, which also proves the clear itself.
            local forgot = 0
            local real_forget = cmd.forget_focus
            cmd.forget_focus = function() forgot = forgot + 1; real_forget() end
            assert.is_nil(Cookie.set("CSRF-TOKEN=abc; _session_id=xyz"))
            cmd.forget_focus = real_forget
            assert.are.same({}, (completed.get()))
            assert.are.same({}, completed.get_details())
            assert.is_nil(session.get("some-kata", "python"))
            assert.are.equal("", config.user.username)
            assert.are.equal(1, forgot, "identity_changed did not forget the focus kata")
        end)

        it("on sign-out", function()
            Cookie.delete()
            assert.are.same({}, (completed.get()))
            assert.is_nil(session.get("some-kata", "python"))
            assert.are.equal("", config.user.username)
        end)

        it("keeps going when one hook fails", function()
            package.loaded["codewars.picker"] = { invalidate_completed_cache = function() error("boom") end }
            Cookie.delete()
            assert.are.equal("", config.user.username)
            assert.is_nil(session.get("some-kata", "python"))
            package.loaded["codewars.picker"] = nil
        end)
    end)
end)

describe("Cookie.parse", function()
    local Cookie = require("codewars.cache.cookie")

    it("parses valid cookie string", function()
        local cookie, err = Cookie.parse("CSRF-TOKEN=abc123; _session_id=xyz789;")
        assert.is_nil(err)
        assert.is_not_nil(cookie)
        assert.are.equal("abc123", cookie.csrf_token)
        assert.are.equal("xyz789", cookie.session_id)
    end)

    it("parses without trailing semicolons", function()
        local cookie, err = Cookie.parse("CSRF-TOKEN=abc123; _session_id=xyz789")
        assert.is_nil(err)
        assert.are.equal("abc123", cookie.csrf_token)
        assert.are.equal("xyz789", cookie.session_id)
    end)

    it("returns error for missing CSRF-TOKEN", function()
        local cookie, err = Cookie.parse("_session_id=xyz789;")
        assert.is_nil(cookie)
        assert.is_not_nil(err)
        assert.truthy(err:find("CSRF"))
    end)

    it("returns error for missing _session_id", function()
        local cookie, err = Cookie.parse("CSRF-TOKEN=abc123;")
        assert.is_nil(cookie)
        assert.is_not_nil(err)
        assert.truthy(err:find("session_id"))
    end)

    it("handles case-insensitive CSRF (csrf-token)", function()
        local cookie, err = Cookie.parse("csrf-token=abc123; _session_id=xyz789;")
        assert.is_nil(err)
        assert.are.equal("abc123", cookie.csrf_token)
    end)

    it("returns error for empty string", function()
        local cookie, err = Cookie.parse("")
        assert.is_nil(cookie)
        assert.is_not_nil(err)
    end)

    it("handles URL-encoded CSRF token values", function()
        local cookie, err = Cookie.parse("CSRF-TOKEN=abc%3D123; _session_id=xyz789;")
        assert.is_nil(err)
        assert.are.equal("abc%3D123", cookie.csrf_token)
    end)

    it("preserves original string", function()
        local str = "CSRF-TOKEN=abc123; _session_id=xyz789;"
        local cookie = Cookie.parse(str)
        assert.are.equal(str, cookie.str)
    end)
end)
