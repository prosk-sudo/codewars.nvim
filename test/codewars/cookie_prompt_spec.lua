-- The two-box flow is where a mis-paste becomes a stored cookie, so it is
-- driven here with the input boxes stubbed out: nui's prompt buffer is not
-- the part that can be wrong.
describe("cmd.cookie_prompt", function()
    local Path = require("plenary.path")
    local real_utils = package.loaded["codewars.cache.utils"]
    local cmd, Cookie, real_ask, titles

    --- Script the boxes: each entry is what that box "returns", or false to
    --- back out of it. Records the titles so skipped boxes are visible.
    local function boxes(...)
        local scripted = { ... }
        local i = 0
        cmd._ask_cookie_value = function(title, on_value, on_cancel)
            i = i + 1
            titles[#titles + 1] = title
            local answer = scripted[i]
            if answer == false then return on_cancel() end
            on_value(answer)
        end
    end

    before_each(function()
        local dir = Path:new(vim.fn.tempname())
        dir:mkdir({ parents = true })
        package.loaded["codewars.cache.utils"] = vim.tbl_extend("force", real_utils or {}, {
            cache_file = function(name) return dir:joinpath(name) end,
        })
        package.loaded["codewars.cache.cookie"] = nil
        Cookie = require("codewars.cache.cookie")

        cmd = require("codewars.command")
        real_ask = cmd._ask_cookie_value
        titles = {}
    end)
    after_each(function()
        cmd._ask_cookie_value = real_ask
        package.loaded["codewars.cache.utils"] = real_utils
        package.loaded["codewars.cache.cookie"] = nil
    end)

    it("splices two bare values into one cookie", function()
        boxes("abc", "xyz")
        local ok
        cmd.cookie_prompt(function(v) ok = v end)

        assert.is_true(ok)
        assert.equals(2, #titles)
        local c = Cookie.get()
        assert.equals("abc", c.csrf_token)
        assert.equals("xyz", c.session_id)
    end)

    it("skips the second box when the first already holds both values", function()
        boxes("CSRF-TOKEN=abc; _session_id=xyz")
        local ok
        cmd.cookie_prompt(function(v) ok = v end)

        assert.is_true(ok)
        assert.equals(1, #titles) -- the second box was never opened
        assert.equals("xyz", Cookie.get().session_id)
    end)

    -- The bug this flow shipped with: box 1 advertises the combined paste, so
    -- the same clipboard reaching box 2 is a natural mistake. It reported a
    -- successful sign-in and stored "CSRF-TOKEN=abc" as the session id.
    it("survives the whole header being pasted into the second box", function()
        boxes("abc", "CSRF-TOKEN=abc; _session_id=xyz")
        local ok
        cmd.cookie_prompt(function(v) ok = v end)

        assert.is_true(ok)
        assert.equals("xyz", Cookie.get().session_id)
    end)

    it("reports failure without storing anything when a value is unusable", function()
        boxes("ab;c", "xyz")
        local ok
        cmd.cookie_prompt(function(v) ok = v end)

        assert.is_false(ok)
        assert.is_nil(Cookie.get())
    end)

    it("backing out of the first box stores nothing and reports failure", function()
        boxes(false)
        local ok
        cmd.cookie_prompt(function(v) ok = v end)

        assert.is_false(ok)
        assert.is_nil(Cookie.get())
    end)

    it("backing out of the second box stores nothing and reports failure", function()
        boxes("abc", false)
        local ok
        cmd.cookie_prompt(function(v) ok = v end)

        assert.is_false(ok)
        assert.is_nil(Cookie.get())
    end)

    -- `:CW cookie` reaches this through cmd.exec, which calls the handler
    -- with the parsed options TABLE, not a callback -- the case the guard at
    -- the top of cookie_prompt exists for, and the commonest way to sign in.
    it("works when invoked as a command, with no callback to answer", function()
        boxes("abc", "xyz")
        assert.has_no.errors(function()
            cmd.cookie_prompt(vim.tbl_extend("force", vim.empty_dict(), { _positional = {} }))
        end)
        assert.equals("xyz", Cookie.get().session_id)

        boxes("def", "uvw")
        assert.has_no.errors(function() cmd.cookie_prompt() end)
        assert.equals("uvw", Cookie.get().session_id)
    end)

    it("names each box in its own prompt", function()
        boxes("abc", "xyz")
        cmd.cookie_prompt(function() end)

        assert.truthy(titles[1]:find("CSRF-TOKEN", 1, true))
        assert.truthy(titles[2]:find("_session_id", 1, true))
        assert.is_nil(titles[1]:find("_session_id", 1, true))
    end)

    -- Asking for the second value and only then blaming the first box wastes
    -- a step the user cannot act on.
    it("refuses an empty first box without opening the second", function()
        boxes("   ", "xyz")
        local ok
        cmd.cookie_prompt(function(v) ok = v end)

        assert.is_false(ok)
        assert.equals(1, #titles)
        assert.is_nil(Cookie.get())
    end)

    it("answers the caller exactly once", function()
        boxes("abc", "xyz")
        local calls = 0
        cmd.cookie_prompt(function() calls = calls + 1 end)

        assert.equals(1, calls)
    end)
end)
