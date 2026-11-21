-- api.search had no spec at all, which is why a rate-limited page came back
-- as an EMPTY page for so long: the cache build read that as "end of this
-- rank" and silently truncated, and the interactive search reported
-- "No kata found".
describe("api.search", function()
    local warnings = {}
    package.loaded["codewars.logger"] = {
        info = function() end, warn = function(msg) warnings[#warnings + 1] = tostring(msg) end,
        error = function() end, err = function() end, debug = function() end,
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

    -- One result row in the shape parse_html ACTUALLY expects: it splits on
    -- the literal "list-item-kata" and requires a hex id in the href. The
    -- previous fixture had neither, parsed to {}, and let the happy-path
    -- tests pass while asserting nothing about results.
    local SLUG = "5277c8a221e209d3f6000b56"
    local function page_html()
        return ([[<div class="list-item-kata" id="%s"><span>7 kyu</span>
            <div class="item-title"><a href="/kata/%s">Valid Braces</a></div></div>]]):format(SLUG, SLUG)
    end

    --- A result block around `inner`, laid out as the real page does.
    local function block(inner)
        return ([[<div class="list-item-kata bg-ui-section" id="%s"><div><span>6 kyu</span>%s</div></div>]]):format(SLUG, inner)
    end
    --- A block whose title link parses.
    local function readable(name)
        return block(('<a class="ml-2" href="/kata/%s">%s</a>'):format(SLUG, name or "Braces"))
    end
    --- A block the parser cannot read: the title link left /kata/<hex>.
    local function unreadable()
        return block('<a class="ml-2" href="/challenges/valid-braces">Braces</a>')
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
        warnings = {}
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
            assert.are.equal(1, #got[1])
            assert.are.equal(SLUG, got[1][1].slug)
            assert.are.equal("Valid Braces", got[1][1].name)
            assert.is_true(got[2]) -- has_more
        end)

        it("requests the page with an HTML Accept header through api.utils", function()
            table.insert(responses, { exit = 0, status = 200, body = page_html() })
            drive(function(cb) search.fetch_page({ language = "python", query = "braces" }, 2, cb) end)
            assert.are.equal(1, #calls)
            assert.truthy(calls[1]:find("/kata/search/python?", 1, true))
            assert.truthy(calls[1]:find("page=2", 1, true))
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

        it("passes non-retryable failures through without retrying", function()
            table.insert(responses, { exit = 0, status = 404, body = "" })
            local got = drive(function(cb)
                search.fetch_page({ language = "python" }, 0, cb)
            end)
            assert.are.equal(1, #calls)
            assert.is_not_nil(got[3])
            assert.is_nil(got[3].rate_limited)
        end)

        -- A transient 5xx is retried like every other GET; if it persists
        -- it MUST surface as an error, never as an empty page, or the cache
        -- build ends the rank early and writes the truncated list as fresh.
        it("retries a 5xx and reports it as an error when it persists", function()
            for _ = 1, 10 do
                table.insert(responses, { exit = 0, status = 502, body = "" })
            end
            local got = drive(function(cb)
                search.fetch_page({ language = "python" }, 0, cb)
            end)
            assert.are.equal(4, #calls)
            assert.are.same({}, got[1])
            assert.is_not_nil(got[3])
            assert.are.equal(502, got[3].status)
        end)

        it("reports a curl failure (no connection) instead of never calling back", function()
            package.loaded["plenary.curl"].get = function(url, opts)
                table.insert(calls, url)
                -- plenary invokes on_error instead of callback when curl exits non-zero
                opts.on_error({ message = "curl error", stderr = "", exit = 6 })
            end
            local got = drive(function(cb)
                search.fetch_page({ language = "python" }, 0, cb)
            end)
            assert.are.equal(1, #calls)
            assert.are.equal(6, got[3].code)
            package.loaded["plenary.curl"].get = function(url, opts)
                table.insert(calls, url)
                local r = table.remove(responses, 1) or { exit = 0, status = 200, body = "" }
                opts.callback(r)
            end
        end)

        it("stops retrying once the caller reports it has given up", function()
            limited(10)
            local gave_up = false
            local got = drive(function(cb)
                search.fetch_page({ language = "python", cancelled = function() return gave_up end }, 0, function(...)
                    cb(...)
                end)
                gave_up = true
            end)
            assert.are.equal(1, #calls)
            assert.is_true(got[3].rate_limited)
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
            -- Both pages were requested (the first said has_more) and the
            -- result actually made it through, not just "no error".
            assert.are.equal(2, #calls)
            assert.are.equal(1, #got[1])
            assert.are.equal(SLUG, got[1][1].slug)
        end)
    end)

    -- The search page is HTML: a name with an apostrophe arrives as
    -- `&#39;`, and the kata list showed it that way.
    describe("parse_html", function()
        it("decodes HTML entities in kata names", function()
            local html = ([[<div class="list-item-kata" id="%s"><span>6 kyu</span>
                <a class="ml-2" href="/kata/%s">My Very Own Python&#39;s Split &amp; Join</a></div>]]):format(SLUG, SLUG)
            local results = search.parse_html(html)
            assert.are.equal(1, #results)
            assert.are.equal("My Very Own Python's Split & Join", results[1].name)
        end)
    end)

    -- Result links used to be matched as exactly `href="/kata/<hex>">`, so
    -- any drift from that -- a class after the href, single quotes, a
    -- trailing path -- dropped the kata without a word.
    describe("parse_html result links", function()
        local function parse_link(anchor)
            return search.parse_html(block(anchor))
        end

        it("accepts attributes after the href", function()
            local results = parse_link(('<a href="/kata/%s" class="ml-2" data-x="1">Braces</a>'):format(SLUG))
            assert.are.equal(1, #results)
            assert.are.equal(SLUG, results[1].slug)
            assert.are.equal("Braces", results[1].name)
        end)

        it("accepts single quotes", function()
            local results = parse_link(("<a class='ml-2' href='/kata/%s'>Braces</a>"):format(SLUG))
            assert.are.equal(1, #results)
            assert.are.equal(SLUG, results[1].slug)
        end)

        it("accepts a trailing path, as /kata/<hex>/train/python", function()
            local results = parse_link(('<a href="/kata/%s/train/python">Braces</a>'):format(SLUG))
            assert.are.equal(1, #results)
            assert.are.equal(SLUG, results[1].slug)
            assert.are.equal("Braces", results[1].name)
        end)

        it("accepts a trailing query or fragment", function()
            assert.are.equal(1, #parse_link(('<a href="/kata/%s?beta=false">Braces</a>'):format(SLUG)))
            assert.are.equal(1, #parse_link(('<a href="/kata/%s#discuss">Braces</a>'):format(SLUG)))
        end)

        it("names the kata from its own link, not a train link that comes first", function()
            local results = parse_link(
                ('<a href="/kata/%s/train/python">Train</a><a href="/kata/%s">Valid Braces</a>'):format(SLUG, SLUG)
            )
            assert.are.equal("Valid Braces", results[1].name)
        end)

        it("skips the language icons, which carry a train link and no text", function()
            local results = parse_link(
                ('<a data-language="python" href="/kata/%s/train/python"><div class="icon"></div></a>'
                    .. '<a href="/kata/%s">Valid Braces</a>'):format(SLUG, SLUG)
            )
            assert.are.equal("Valid Braces", results[1].name)
        end)

        it("does not take a data-href for the link", function()
            assert.are.equal(0, #parse_link(('<a data-href="/kata/%s">Braces</a>'):format(SLUG)))
        end)

        it("does not accept an id that is not 24 hex characters", function()
            for _, id in ipairs({
                SLUG:sub(1, 23), -- too short
                SLUG .. "a", -- too long
                SLUG:sub(1, 23) .. "g", -- not hex
                "valid-braces", -- a slug, not an id
                "bead", -- hex, but not an id
            }) do
                assert.are.equal(0, #parse_link(('<a href="/kata/%s">Braces</a>'):format(id)), id)
            end
        end)
    end)

    -- A page with result blocks that parses to nothing is not a rank that
    -- ran out: the markup moved. Reported as an error, it stops a cache
    -- build instead of ending the rank early and caching the short list.
    describe("parse_html markup drift", function()
        it("is not an error when the page has no result blocks", function()
            local results, err, dropped = search.parse_html("<html><body>No kata found</body></html>")
            assert.are.same({}, results)
            assert.is_nil(err)
            assert.are.equal(0, dropped)
        end)

        it("is an error when the page has result blocks and none can be read", function()
            local results, err, dropped = search.parse_html(unreadable() .. unreadable())
            assert.are.same({}, results)
            assert.is_true(err.drift)
            assert.truthy(err.msg:find("markup may have changed", 1, true), err.msg)
            assert.are.equal(2, dropped)
        end)

        it("keeps the blocks it can read and counts the others", function()
            local results, err, dropped = search.parse_html(readable("One") .. unreadable() .. readable("Two"))
            assert.is_nil(err)
            assert.are.equal(2, #results)
            assert.are.equal("One", results[1].name)
            assert.are.equal("Two", results[2].name)
            assert.are.equal(1, dropped)
        end)

        it("counts nothing dropped on a clean page", function()
            local _, err, dropped = search.parse_html(readable("One") .. readable("Two"))
            assert.is_nil(err)
            assert.are.equal(0, dropped)
        end)
    end)

    describe("fetch_page markup drift", function()
        it("reports a page whose blocks all fail to parse as an error, not the end of a rank", function()
            table.insert(responses, { exit = 0, status = 200, body = unreadable() })
            local got = drive(function(cb) search.fetch_page({ language = "python" }, 0, cb) end)
            assert.are.same({}, got[1])
            assert.is_false(got[2])
            assert.is_true(got[3].drift)
        end)

        it("still reports a page with no result blocks as the end of a rank", function()
            table.insert(responses, { exit = 0, status = 200, body = "<html>No kata found</html>" })
            local got = drive(function(cb) search.fetch_page({ language = "python" }, 0, cb) end)
            assert.are.same({}, got[1])
            assert.is_false(got[2])
            assert.is_nil(got[3])
        end)

        it("hands back what it parsed and how many blocks it left out", function()
            table.insert(responses, { exit = 0, status = 200, body = readable("One") .. unreadable() })
            local got = drive(function(cb) search.fetch_page({ language = "python" }, 0, cb) end)
            assert.are.equal(1, #got[1])
            assert.is_true(got[2])
            assert.is_nil(got[3])
            assert.are.equal(1, got[4])
        end)

        it("hands back zero dropped for a clean page", function()
            table.insert(responses, { exit = 0, status = 200, body = page_html() })
            local got = drive(function(cb) search.fetch_page({ language = "python" }, 0, cb) end)
            assert.are.equal(0, got[4])
        end)

        it("does not warn per page", function()
            table.insert(responses, { exit = 0, status = 200, body = readable("One") .. unreadable() })
            drive(function(cb) search.fetch_page({ language = "python" }, 0, cb) end)
            assert.are.same({}, warnings)
        end)
    end)

    describe("kata markup drift", function()
        it("propagates the error to its caller", function()
            table.insert(responses, { exit = 0, status = 200, body = unreadable() })
            local got = drive(function(cb) search.kata({ language = "python", max_pages = 3 }, cb) end)
            assert.is_true(got[2].drift)
            assert.are.same({}, got[1])
        end)

        it("warns once with the total dropped, not once per page", function()
            table.insert(responses, { exit = 0, status = 200, body = readable("One") .. unreadable() })
            table.insert(responses, { exit = 0, status = 200, body = readable("Two") .. unreadable() .. unreadable() })
            table.insert(responses, { exit = 0, status = 200, body = "" })
            local got = drive(function(cb) search.kata({ language = "python", max_pages = 3 }, cb) end)
            assert.is_nil(got[2])
            assert.are.equal(2, #got[1])
            assert.are.equal(1, #warnings, vim.inspect(warnings))
            assert.truthy(warnings[1]:find("3", 1, true), warnings[1])
        end)

        it("does not warn when nothing was dropped", function()
            table.insert(responses, { exit = 0, status = 200, body = page_html() })
            table.insert(responses, { exit = 0, status = 200, body = "" })
            drive(function(cb) search.kata({ language = "python", max_pages = 3 }, cb) end)
            assert.are.same({}, warnings)
        end)
    end)
end)
