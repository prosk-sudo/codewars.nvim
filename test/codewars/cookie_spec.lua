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
