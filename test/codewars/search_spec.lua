-- api.search had no spec at all, which is why a rate-limited page came back
-- as an EMPTY page for so long: the cache build read that as "end of this
-- rank" and silently truncated, and the interactive search reported
-- "No kata found".
describe("api.search", function()
    package.loaded["codewars.logger"] = {
        info = function() end, warn = function() end, error = function() end,
        err = function() end, debug = function() end,
    }
    package.loaded["codewars.config"] = { lang = "python", user = {} }
    package.loaded["codewars.api.headers"] = { get = function() return {} end }

    local calls = {}
    local responses = {}
    package.loaded["plenary.curl"] = {
        get = function(url, opts)
            table.insert(calls, url)
            local r = table.remove(responses, 1) or { exit = 0, status = 200, body = "" }
            opts.callback(r)
        end,
    }

    package.loaded["codewars.api.utils"] = nil
    package.loaded["codewars.api.search"] = nil
    local api_utils = require("codewars.api.utils")
    local search = require("codewars.api.search")
    api_utils.retry_delay_ms = function() return 1 end

    -- One result row in the shape parse_html expects, so a "success" page is
    -- distinguishable from an empty one.
    local function page_html()
        return [[<div class="item-title"><a href="/kata/valid-braces">Valid Braces</a></div>]]
    end

    local function limited(n)
        for _ = 1, n do
            table.insert(responses, { exit = 0, status = 429, body = "", headers = {} })
        end
    end

    --- Drive an async callback to completion.
    local function drive(fn)
        local done, captured = false, nil
        fn(function(...) captured = { ... }; done = true end)
        vim.wait(2000, function() return done end)
        assert.is_true(done, "callback never fired")
        return captured
    end

    before_each(function()
        calls = {}
        responses = {}
    end)

    describe("fetch_page", function()
        it("retries a rate-limited page and returns the eventual results", function()
            limited(2)
            table.insert(responses, { exit = 0, status = 200, body = page_html() })
            local got = drive(function(cb)
                search.fetch_page({ language = "python" }, 0, cb)
            end)
            assert.are.equal(3, #calls)
            assert.is_nil(got[3]) -- no error
        end)

        -- The whole point: exhausted rate limiting must NOT look like an
        -- empty page, or callers treat it as "no more results".
        it("reports rate limiting as an error, never as an empty page", function()
            limited(10)
            local got = drive(function(cb)
                search.fetch_page({ language = "python" }, 0, cb)
            end)
            local results, has_more, err = got[1], got[2], got[3]
            assert.are.same({}, results)
            assert.is_false(has_more)
            assert.is_true(err.rate_limited)
            assert.are.equal(429, err.status)
        end)

        it("stops after MAX_ATTEMPTS rather than retrying forever", function()
            limited(10)
            drive(function(cb) search.fetch_page({ language = "python" }, 0, cb) end)
            assert.are.equal(4, #calls)
        end)

        it("surfaces an expired session as an auth error, without retrying", function()
            table.insert(responses, { exit = 0, status = 401, body = "" })
            local got = drive(function(cb)
                search.fetch_page({ language = "python" }, 0, cb)
            end)
            assert.are.equal(1, #calls)
            assert.is_true(got[3].auth)
        end)

        it("passes other failures through without retrying", function()
            table.insert(responses, { exit = 0, status = 500, body = "" })
            local got = drive(function(cb)
                search.fetch_page({ language = "python" }, 0, cb)
            end)
            assert.are.equal(1, #calls)
            assert.is_not_nil(got[3])
            assert.is_nil(got[3].rate_limited)
        end)
    end)

    describe("kata", function()
        -- picker.problems already destructures (results, err); search.kata
        -- simply never passed one, so a rate-limited search said
        -- "No kata found".
        it("propagates a rate-limit error to its caller", function()
            limited(10)
            local got = drive(function(cb)
                search.kata({ language = "python", max_pages = 3 }, cb)
            end)
            local results, err = got[1], got[2]
            assert.is_not_nil(err, "search.kata swallowed the error")
            assert.is_true(err.rate_limited)
            assert.are.same({}, results)
        end)

        it("propagates an auth error to its caller", function()
            table.insert(responses, { exit = 0, status = 403, body = "" })
            local got = drive(function(cb)
                search.kata({ language = "python", max_pages = 3 }, cb)
            end)
            assert.is_true(got[2].auth)
        end)

        it("returns results with no error on the happy path", function()
            table.insert(responses, { exit = 0, status = 200, body = page_html() })
            table.insert(responses, { exit = 0, status = 200, body = "" })
            local got = drive(function(cb)
                search.kata({ language = "python", max_pages = 2 }, cb)
            end)
            assert.is_nil(got[2])
        end)
    end)
end)
