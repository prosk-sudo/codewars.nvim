-- The retry lifecycle in api.utils.curl. Nothing in the suite stubbed
-- plenary.curl before, so the whole should_retry path was unexercised --
-- which is how a 429 branch shipped that called a function that did not
-- exist.
--
-- These drive the SYNCHRONOUS path (no callback) deliberately: it recurses
-- inline instead of going through vim.defer_fn, so the assertions are
-- deterministic and the test does not race a timer.
describe("api.utils retry lifecycle", function()
    package.loaded["codewars.logger"] = {
        info = function() end,
        warn = function() end,
        error = function() end,
        err = function() end,
        debug = function() end,
    }
    package.loaded["codewars.api.headers"] = { get = function() return {} end }

    local calls = {}
    local responses = {}
    package.loaded["plenary.curl"] = setmetatable({}, {
        __index = function(_, method)
            return function(url, opts)
                table.insert(calls, { method = method, url = url, retry = opts.retry })
                local r = table.remove(responses, 1) or { exit = 0, status = 200, body = "{}" }
                if opts.callback then return opts.callback(r) end
                return r
            end
        end,
    })

    package.loaded["codewars.api.utils"] = nil
    local api_utils = require("codewars.api.utils")
    -- Keep the waits negligible; timing is covered by retry_delay_ms's own
    -- tests, and real backoff here would make the suite crawl.
    api_utils.retry_delay_ms = function() return 1 end

    local function rate_limited(n)
        for _ = 1, n do
            table.insert(responses, { exit = 0, status = 429, body = "", headers = {} })
        end
    end

    before_each(function()
        calls = {}
        responses = {}
    end)

    it("retries a rate-limited GET and returns the eventual success", function()
        rate_limited(2)
        table.insert(responses, { exit = 0, status = 200, body = '{"ok":true}' })
        local res, err = api_utils.get("/x")
        assert.are.equal(3, #calls)
        assert.is_nil(err)
        assert.is_true(res.ok)
    end)

    it("gives up after the retry budget and returns the rate-limit error", function()
        rate_limited(10)
        local _, err = api_utils.get("/x", { retry = 2 })
        assert.are.equal(3, #calls) -- initial + 2 retries
        assert.is_true(err.rate_limited)
    end)

    it("retries 5xx as before", function()
        table.insert(responses, { exit = 0, status = 503, body = "" })
        table.insert(responses, { exit = 0, status = 200, body = "{}" })
        api_utils.get("/x")
        assert.are.equal(2, #calls)
    end)

    it("does not retry a 404", function()
        table.insert(responses, { exit = 0, status = 404, body = '{"reason":"nope"}' })
        local _, err = api_utils.get("/x")
        assert.are.equal(1, #calls)
        assert.are.equal(404, err.status)
    end)

    it("honors retry = 0, which is how destructive callers opt out", function()
        rate_limited(3)
        local _, err = api_utils.get("/x", { retry = 0 })
        assert.are.equal(1, #calls)
        assert.is_true(err.rate_limited)
    end)

    -- A 429 means refused, so repeating is usually safe -- but not provably,
    -- and a duplicate publish or double-registered solve is user-visible.
    -- Mutating verbs must not gain automatic retry from a rate-limit fix.
    it("does NOT auto-retry a rate-limited POST", function()
        rate_limited(3)
        local _, err = api_utils.post("/x", { body = { a = 1 } })
        assert.are.equal(1, #calls)
        assert.is_true(err.rate_limited)
    end)

    it("does NOT auto-retry a rate-limited PUT or DELETE", function()
        rate_limited(3)
        api_utils.put("/x", { body = { a = 1 } })
        assert.are.equal(1, #calls)

        calls, responses = {}, {}
        rate_limited(3)
        api_utils.delete("/x")
        assert.are.equal(1, #calls)
    end)

    it("lets a POST opt in explicitly", function()
        rate_limited(1)
        table.insert(responses, { exit = 0, status = 200, body = "{}" })
        api_utils.post("/x", { body = { a = 1 }, retry_rate_limited = true })
        assert.are.equal(2, #calls)
    end)

    it("still retries a 5xx POST (refused-vs-performed does not apply)", function()
        table.insert(responses, { exit = 0, status = 502, body = "" })
        table.insert(responses, { exit = 0, status = 200, body = "{}" })
        api_utils.post("/x", { body = { a = 1 } })
        assert.are.equal(2, #calls)
    end)

    it("counts down the retry budget across recursions", function()
        rate_limited(10)
        api_utils.get("/x", { retry = 3 })
        assert.are.same({ 3, 2, 1, 0 }, {
            calls[1].retry, calls[2].retry, calls[3].retry, calls[4].retry,
        })
    end)
end)
