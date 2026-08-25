describe("api.utils", function()
    local api_utils = require("codewars.api.utils")

    describe("header_value", function()
        it("finds a header regardless of case", function()
            local hdrs = { "HTTP/2 429", "Retry-After: 12", "Content-Type: text/html" }
            assert.are.equal("12", api_utils.header_value(hdrs, "retry-after"))
            assert.are.equal("12", api_utils.header_value(hdrs, "Retry-After"))
            assert.are.equal("12", api_utils.header_value(hdrs, "RETRY-AFTER"))
        end)

        it("trims trailing whitespace", function()
            assert.are.equal("12", api_utils.header_value({ "Retry-After: 12   " }, "retry-after"))
        end)

        -- Returning zero values (rather than nil) made tonumber() throw,
        -- because tonumber() with no argument at all is an error.
        it("returns nil, not nothing, when the header is absent", function()
            local v = api_utils.header_value({ "X: y" }, "retry-after")
            assert.is_nil(v)
            assert.has_no.errors(function() return tonumber(api_utils.header_value({ "X: y" }, "retry-after")) end)
        end)

        it("tolerates a nil or non-table header list", function()
            assert.is_nil(api_utils.header_value(nil, "retry-after"))
            assert.is_nil(api_utils.header_value("not a table", "retry-after"))
            assert.is_nil(api_utils.header_value({}, "retry-after"))
        end)

        it("ignores a line with no colon", function()
            assert.is_nil(api_utils.header_value({ "garbage" }, "retry-after"))
        end)
    end)

    describe("retry_delay_ms", function()
        it("honors Retry-After exactly, without jitter", function()
            assert.are.equal(3000, api_utils.retry_delay_ms({ retry_after = 3 }, 0))
            assert.are.equal(1000, api_utils.retry_delay_ms({ retry_after = 1 }, 5))
        end)

        it("clamps an absurd Retry-After to MAX_BACKOFF_MS", function()
            assert.are.equal(api_utils.MAX_BACKOFF_MS, api_utils.retry_delay_ms({ retry_after = 99999 }, 0))
        end)

        it("ignores a zero or negative Retry-After and backs off instead", function()
            assert.is_true(api_utils.retry_delay_ms({ retry_after = 0 }, 0) > 0)
            assert.is_true(api_utils.retry_delay_ms({ retry_after = -5 }, 0) > 0)
        end)

        -- The backoff used to be derived from a counter that shrank on every
        -- recursion, so attempt was always 0 and every wait was the same
        -- 500ms. Assert it actually grows.
        it("grows with the attempt count", function()
            local function span(attempt)
                local lo, hi = math.huge, 0
                for _ = 1, 60 do
                    local d = api_utils.retry_delay_ms({}, attempt)
                    lo, hi = math.min(lo, d), math.max(hi, d)
                end
                return lo, hi
            end
            local lo0, hi0 = span(0)
            local lo1, hi1 = span(1)
            local lo2 = span(2)
            assert.is_true(hi0 < lo1, ("attempt 0 max %d should be below attempt 1 min %d"):format(hi0, lo1))
            assert.is_true(hi1 < lo2, ("attempt 1 max %d should be below attempt 2 min %d"):format(hi1, lo2))
            assert.is_true(lo0 > 0)
        end)

        it("clamps the exponential branch and stays jittered around the cap", function()
            for _ = 1, 40 do
                local d = api_utils.retry_delay_ms({}, 20)
                assert.is_true(d <= api_utils.MAX_EXP_BACKOFF_MS)
                assert.is_true(d >= math.floor(api_utils.MAX_EXP_BACKOFF_MS * 0.75))
            end
        end)

        -- Retry-After may be an HTTP-date, which tonumber cannot read. The
        -- server still asked for a wait, so start long rather than short.
        it("starts at the longest backoff when Retry-After was unparseable", function()
            local unparseable = { retry_after_raw = "Wed, 21 Oct 2026 07:28:00 GMT" }
            for _ = 1, 20 do
                local d = api_utils.retry_delay_ms(unparseable, 0)
                assert.is_true(d >= math.floor(api_utils.MAX_EXP_BACKOFF_MS * 0.75))
            end
        end)

        it("handles a nil err and a nil attempt", function()
            assert.is_true(api_utils.retry_delay_ms(nil, nil) > 0)
        end)
    end)

    describe("handle_res error bodies", function()
        it("does not crash when a JSON reason is a table", function()
            local ok, res, err = pcall(api_utils.handle_res, {
                exit = 0, status = 422, headers = {},
                body = '{"reason":{"field":"title"}}',
            })
            assert.is_true(ok, tostring(res))
            assert.are.equal(422, err.status)
            assert.truthy(err.msg:find("title", 1, true))
        end)
    end)

    -- plenary's Job:new raises ("Executable not found") before the job
    -- runs, so the on_error hook never sees a missing curl: the raise
    -- escaped into whatever UI flow made the request.
    describe("curl spawn failure", function()
        local curl = require("plenary.curl")
        local real_get = curl.get
        after_each(function() curl.get = real_get end)

        it("reaches the async callback as a curl error instead of raising", function()
            curl.get = function() error("curl: Executable not found") end
            local done, err
            local ok, raised = pcall(api_utils.get, "/x", { retry = 0, callback = function(_, e) err = e; done = true end })
            assert.is_true(ok, tostring(raised))
            vim.wait(1000, function() return done end)
            assert.is_true(done, "callback never fired")
            assert.are.equal(127, err.code)
        end)

        it("returns a curl error from the sync path instead of raising", function()
            curl.get = function() error("curl: Executable not found") end
            local ok, res, err = pcall(api_utils.get, "/x", { retry = 0 })
            assert.is_true(ok, tostring(res))
            assert.is_nil(res)
            assert.are.equal(127, err.code)
        end)
    end)

    describe("handle_res 429", function()
        it("classifies 429 as rate limited and parses Retry-After", function()
            local _, err = api_utils.handle_res({
                exit = 0, status = 429, body = "", headers = { "Retry-After: 7" },
            })
            assert.are.equal(429, err.status)
            assert.is_true(err.rate_limited)
            assert.are.equal(7, err.retry_after)
        end)

        it("still flags rate limiting when no Retry-After is sent", function()
            local _, err = api_utils.handle_res({ exit = 0, status = 429, body = "", headers = {} })
            assert.is_true(err.rate_limited)
            assert.is_nil(err.retry_after)
        end)

        it("keeps an unparseable Retry-After as raw", function()
            local _, err = api_utils.handle_res({
                exit = 0, status = 429, body = "", headers = { "Retry-After: Wed, 21 Oct 2026 07:28:00 GMT" },
            })
            assert.is_nil(err.retry_after)
            assert.is_not_nil(err.retry_after_raw)
        end)

        it("does not throw when headers are missing entirely", function()
            assert.has_no.errors(function()
                api_utils.handle_res({ exit = 0, status = 429, body = "" })
            end)
        end)

        it("does not mark other statuses as rate limited", function()
            local _, e404 = api_utils.handle_res({ exit = 0, status = 404, body = '{"reason":"x"}' })
            local _, e500 = api_utils.handle_res({ exit = 0, status = 500, body = "" })
            assert.is_nil(e404.rate_limited)
            assert.is_nil(e500.rate_limited)
        end)
    end)

    describe("handle_res auth detection", function()
        it("detects 401 as auth error", function()
            local _, err = api_utils.handle_res({ exit = 0, status = 401, body = '{"error":"Unauthorized"}' })
            assert.is_not_nil(err)
            assert.truthy(err.auth)
            assert.truthy(err.msg:find("Session expired"))
        end)

        it("detects 403 as auth error", function()
            local _, err = api_utils.handle_res({ exit = 0, status = 403, body = "Forbidden" })
            assert.is_not_nil(err)
            assert.truthy(err.auth)
        end)

        it("does not flag 404 as auth error", function()
            local _, err = api_utils.handle_res({ exit = 0, status = 404, body = '{"reason":"Not found"}' })
            assert.is_not_nil(err)
            assert.is_nil(err.auth)
            assert.are.equal(404, err.status)
        end)

        it("does not flag 500 as auth error", function()
            local _, err = api_utils.handle_res({ exit = 0, status = 500, body = "Internal Server Error" })
            assert.is_not_nil(err)
            assert.is_nil(err.auth)
            assert.are.equal(500, err.status)
        end)

        it("returns nil error on success", function()
            local res, err = api_utils.handle_res({ exit = 0, status = 200, body = '{"ok":true}' })
            assert.is_nil(err)
            assert.is_not_nil(res)
            assert.truthy(res.ok)
        end)

        it("normalizes JSON null to nil, never vim.NIL (beta kata rank)", function()
            local res = api_utils.handle_res({ exit = 0, status = 200, body = '{"slug":"x","rank":null}' })
            assert.are.equal("x", res.slug)
            assert.is_nil(res.rank)
            assert.are_not.equal(vim.NIL, res.rank)
        end)

        it("keeps null ARRAY elements as vim.NIL (no sequence holes)", function()
            local res = api_utils.handle_res({ exit = 0, status = 200, body = '{"items":[1,null,3]}' })
            assert.are.equal(3, #res.items)
            assert.are.equal(vim.NIL, res.items[2])
            assert.are.equal(3, res.items[3])
        end)
    end)
end)
