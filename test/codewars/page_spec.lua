-- page.fetch used to look only at curl's exit code. curl exits 0 on a 429
-- or a 403, so the HTML error page went to the scrapers as content and was
-- reported as "session expired" or "markup changed". The status now comes
-- from a -D header dump; these cover the pure helpers and the retry loop
-- with jobstart stubbed.
describe("api.page", function()
    package.loaded["codewars.api.headers"] = { get = function() return {} end }
    package.loaded["codewars.api.page"] = nil
    local page = require("codewars.api.page")

    describe("parse_header_dump", function()
        it("takes the LAST hop's status after redirects, and its Retry-After", function()
            local dump = table.concat({
                "HTTP/2 302", "location: /kata/x/solutions/python", "",
                "HTTP/2 429", "retry-after: 7", "content-type: text/html", "",
            }, "\r\n")
            local status, ra = page.parse_header_dump(dump)
            assert.are.equal(429, status)
            assert.are.equal("7", ra)
        end)

        it("does not carry a Retry-After across hops", function()
            local dump = "HTTP/1.1 429\r\nRetry-After: 9\r\n\r\nHTTP/1.1 200\r\n\r\n"
            local status, ra = page.parse_header_dump(dump)
            assert.are.equal(200, status)
            assert.is_nil(ra)
        end)

        it("returns nil for an empty dump", function()
            assert.is_nil((page.parse_header_dump("")))
        end)
    end)

    describe("status_err", function()
        it("is nil for success", function()
            assert.is_nil(page.status_err(200))
            assert.is_nil(page.status_err(nil))
        end)

        it("classifies 429 as rate_limited with Retry-After (raw kept when unparseable)", function()
            local e = page.status_err(429, "30")
            assert.is_true(e.rate_limited)
            assert.are.equal(30, e.retry_after)
            local d = page.status_err(429, "Wed, 21 Oct 2026 07:28:00 GMT")
            assert.is_nil(d.retry_after)
            assert.are.equal("Wed, 21 Oct 2026 07:28:00 GMT", d.retry_after_raw)
        end)

        it("classifies 401/403 as auth, others by status", function()
            assert.is_true(page.status_err(403).auth)
            assert.is_true(page.status_err(401).auth)
            local e = page.status_err(502)
            assert.are.equal(502, e.status)
            assert.is_nil(e.auth)
            assert.is_nil(e.rate_limited)
        end)
    end)

    describe("fetch_err", function()
        it("passes an HTTP-status error through unchanged", function()
            local e = page.status_err(429)
            assert.are.equal(e, page.fetch_err("the leaderboard", e))
        end)
        it("words transport and empty errors per caller", function()
            assert.truthy(page.fetch_err("the leaderboard", { curl = true }).msg:find("curl error", 1, true))
            assert.truthy(page.fetch_err("the leaderboard", { empty = true }).msg:find("Empty response", 1, true))
        end)
    end)

    describe("fetch", function()
        local real_jobstart = vim.fn.jobstart
        local script, runs
        local function write(path, s)
            local f = assert(io.open(path, "w")); f:write(s); f:close()
        end
        before_each(function()
            runs = 0
            require("codewars.api.utils").retry_delay_ms = function() return 1 end
            -- Fake curl: write the scripted header dump / body to the -D / -o
            -- paths, then "exit 0" like real curl does for any HTTP status.
            vim.fn.jobstart = function(cmd, opts)
                runs = runs + 1
                local out, hdr
                for i, a in ipairs(cmd) do
                    if a == "-o" then out = cmd[i + 1] end
                    if a == "-D" then hdr = cmd[i + 1] end
                end
                local r = script(runs)
                write(hdr, r.headers)
                write(out, r.body or "")
                opts.on_exit(0, r.exit or 0)
                return 1
            end
        end)
        after_each(function() vim.fn.jobstart = real_jobstart end)

        local function drive()
            local done, got
            page.fetch("https://www.codewars.com/x", function(body, err) got = { body, err }; done = true end)
            vim.wait(2000, function() return done end)
            assert.is_true(done, "callback never fired")
            return got[1], got[2]
        end

        it("returns the body on 200", function()
            script = function() return { headers = "HTTP/2 200\r\n\r\n", body = "<html>ok</html>" } end
            local body, err = drive()
            assert.is_nil(err)
            assert.are.equal("<html>ok</html>", body)
        end)

        it("reports a 403 as an auth error instead of handing over the error page", function()
            script = function() return { headers = "HTTP/2 403\r\n\r\n", body = "<html>Forbidden</html>" } end
            local body, err = drive()
            assert.is_nil(body)
            assert.is_true(err.auth)
            assert.are.equal(1, runs)
        end)

        it("retries a 429 and returns the eventual page", function()
            script = function(n)
                if n <= 2 then return { headers = "HTTP/2 429\r\nretry-after: 0\r\n\r\n", body = "<html>slow down</html>" } end
                return { headers = "HTTP/2 200\r\n\r\n", body = "<html>ok</html>" }
            end
            local body, err = drive()
            assert.is_nil(err)
            assert.are.equal("<html>ok</html>", body)
            assert.are.equal(3, runs)
        end)

        it("gives up on a persistent 429 with a rate_limited error, never an empty page", function()
            script = function() return { headers = "HTTP/2 429\r\n\r\n", body = "<html>slow down</html>" } end
            local body, err = drive()
            assert.is_nil(body)
            assert.is_true(err.rate_limited)
            assert.are.equal(page.MAX_429_RETRIES + 1, runs)
        end)

        it("still reports a curl failure by exit code", function()
            script = function() return { headers = "", body = "", exit = 6 } end
            local _, err = drive()
            assert.is_true(err.curl)
        end)
    end)
end)
