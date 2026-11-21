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
    -- any drift from that -- a class after the href, single quotes, a title
    -- wrapped in a tag -- dropped the kata without a word. Only the plain
    -- title link names a kata: a train link (`/kata/<hex>/train/python`) is a
    -- button, and never stands in for a title that cannot be read.
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

        it("does not take a link with a deeper path for the kata", function()
            assert.are.equal(0, #parse_link(('<a href="/kata/%s/train/python">Braces</a>'):format(SLUG)))
            assert.are.equal(0, #parse_link(('<a href="/kata/%s/">Braces</a>'):format(SLUG)))
            assert.are.equal(0, #parse_link(('<a href="/kata/%s/solutions">Braces</a>'):format(SLUG)))
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

        it("reads the title through inline tags inside the link", function()
            local results = parse_link(('<a href="/kata/%s"><span>Valid Braces</span></a>'):format(SLUG))
            assert.are.equal(1, #results)
            assert.are.equal(SLUG, results[1].slug)
            assert.are.equal("Valid Braces", results[1].name)

            results = parse_link(('<a class="ml-2" href="/kata/%s">\n  <b>Valid</b> <i class="x">Braces</i>\n</a>'):format(SLUG))
            assert.are.equal("Valid Braces", results[1].name)
        end)

        it("decodes entities in a wrapped title, and keeps escaped markup as text", function()
            local results = parse_link(('<a href="/kata/%s"><span>Python&#39;s &lt;b&gt; &amp; Co</span></a>'):format(SLUG))
            assert.are.equal("Python's <b> & Co", results[1].name)
        end)

        -- The reported case: a train button ahead of a title the parser used
        -- to be unable to read, which then named the kata "Train".
        it("names a span-wrapped title from the title link, not from a train link", function()
            local train = ('<a href="/kata/%s/train/python">Train</a>'):format(SLUG)
            local title = ('<a href="/kata/%s"><span>Valid Braces</span></a>'):format(SLUG)
            assert.are.equal("Valid Braces", parse_link(train .. title)[1].name)
            assert.are.equal("Valid Braces", parse_link(title .. train)[1].name)
        end)

        it("drops a block whose only kata links are train links", function()
            local train = ('<a href="/kata/%s/train/python">Train</a>'):format(SLUG)
            local results, err, dropped = search.parse_html(block(train) .. readable("Valid Braces"))
            assert.is_nil(err)
            assert.are.equal(1, #results)
            assert.are.equal("Valid Braces", results[1].name)
            assert.are.equal(1, dropped)
        end)

        it("treats a page of blocks with only train links as markup drift", function()
            local train = ('<a href="/kata/%s/train/python">Train</a>'):format(SLUG)
            local results, err, dropped = search.parse_html(block(train) .. block(train))
            assert.are.same({}, results)
            assert.is_true(err.drift)
            assert.are.equal(2, dropped)
        end)

        it("drops a block whose title has no text", function()
            for _, inner in ipairs({
                "",
                "   ",
                "<span></span>",
                "<span> </span>",
                "&nbsp;",
                "<img src='x.png'>",
            }) do
                local results, err, dropped = search.parse_html(
                    block(('<a href="/kata/%s">%s</a>'):format(SLUG, inner)) .. readable("Valid Braces")
                )
                assert.is_nil(err)
                assert.are.equal(1, #results, inner)
                assert.are.equal("Valid Braces", results[1].name, inner)
                assert.are.equal(1, dropped, inner)
            end
        end)

        it("treats a page whose titles are all empty as markup drift", function()
            local empty = block(('<a href="/kata/%s"><span></span></a>'):format(SLUG))
            local _, err = search.parse_html(empty .. empty)
            assert.is_true(err.drift)
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

    -- A result is the element that carries `list-item-kata`, from its opening
    -- tag to its own closing tag. Anything outside it -- the next result, a
    -- footer, a "related kata" section -- is not part of it, whatever its
    -- distance, and a link out there must never be taken for its title.
    describe("parse_html block bounds", function()
        local function hex(n) return ("%024x"):format(n) end

        --- A result block laid out as the real page does (nested divs, a title
        --- link, a train link per language icon), `languages` icons long.
        --- `opts.title_href` moves the title link off /kata/<id>; `opts.tag`
        --- is the block's element; `opts.extra` is markup inside the block;
        --- `opts.open_attrs` is more attributes on its opening tag.
        local function result(n, name, languages, opts)
            opts = opts or {}
            local tag = opts.tag or "div"
            local id = hex(n)
            local icons = {}
            for i = 1, languages or 3 do
                local lang = ("lang%02d"):format(i)
                icons[#icons + 1] = ('<li><a class="text-blue-400" data-language="%s" href="/kata/%s/train/%s">'
                    .. '<div class="icon-container mb-3 bg-gray-200 rounded relative" data-progress="0"'
                    .. ' data-tippy-content="%s" data-tippy-placement="bottom"><i class="icon-moon-%s "></i></div></a></li>'
                ):format(lang, id, lang, lang, lang)
            end
            return ('<%s class="list-item-kata bg-ui-section p-4 rounded-lg shadow-md" data-title="%s" id="%s"%s>'
                .. '<div class="flex flex-col md:flex-row"><div class="px-0 w-full md:w-1/2">'
                .. '<div class="text-base font-semibold px-0 flex items-center"><div class="inline-block">'
                .. '<div border="true" class="small-hex is-extra-wide is-white-rank"><div class="inner-small-hex">'
                .. '<span>8 kyu</span></div></div></div>'
                .. '<a class="ml-2" href="%s">%s</a></div>%s</div>'
                .. '<div class="px-0 w-full md:w-1/2"><ul class="icon-list language-icons">%s</ul></div></div></%s>'
            ):format(
                tag, name, id, opts.open_attrs and (" " .. opts.open_attrs) or "",
                opts.title_href or ("/kata/" .. id), name, opts.extra or "", table.concat(icons), tag
            )
        end

        --- Links after the results, as a footer or a related-kata section has.
        local function footer(n)
            return ('<div class="footer"><h3>Related kata</h3><a href="/kata/%s">Related One</a>'
                .. '<a href="/kata/%s/train/python">Train</a><a href="/kata/%s">Related Two</a></div>'):format(hex(n), hex(n), hex(n + 1))
        end

        local function unreadable_title(n, name, languages, opts)
            return result(n, name, languages, vim.tbl_extend("force", opts or {}, { title_href = "/challenges/" .. hex(n) }))
        end

        local function names(results)
            return vim.tbl_map(function(r) return r.name end, results)
        end

        it("reads every block of a full page, with every language", function()
            local html = {}
            for n = 1, 30 do html[#html + 1] = result(n, "Kata " .. n, 5) end
            local results, err, dropped = search.parse_html(table.concat(html) .. footer(900))
            assert.is_nil(err)
            assert.are.equal(30, #results)
            assert.are.equal(0, dropped)
            assert.are.equal("Kata 1", results[1].name)
            assert.are.equal("Kata 30", results[30].name)
            for _, entry in ipairs(results) do
                assert.are.equal(5, #entry.languages, entry.name)
            end
        end)

        -- The last block used to be cut 3000 characters after its marker.
        it("keeps every language of a long last block", function()
            local last = result(2, "Two", 40)
            assert.is_true(#last > 6000, "the fixture should be longer than the old cut")
            local results, err, dropped = search.parse_html(result(1, "One", 3) .. last)
            assert.is_nil(err)
            assert.are.equal(2, #results)
            assert.are.equal(0, dropped)
            assert.are.equal(40, #results[2].languages)
            assert.are.equal("lang40", results[2].languages[40])
        end)

        it("does not name a block whose title is unreadable from a link in the footer after it", function()
            local results, err, dropped = search.parse_html(
                result(1, "One", 3) .. unreadable_title(2, "Two", 2) .. footer(10)
            )
            assert.is_nil(err)
            assert.are.same({ "One" }, names(results))
            assert.are.equal(1, dropped)
        end)

        it("treats a page whose only block has an unreadable title as drift, not a footer link", function()
            local results, err, dropped = search.parse_html(unreadable_title(2, "Two", 2) .. footer(10))
            assert.are.same({}, results)
            assert.is_true(err.drift)
            assert.are.equal(1, dropped)
        end)

        it("keeps a block out of the next one's reach, too", function()
            -- The unreadable block is in the middle: the next block's title is not its own.
            local results, err, dropped = search.parse_html(
                unreadable_title(1, "One", 2) .. result(2, "Two", 2)
            )
            assert.is_nil(err)
            assert.are.same({ "Two" }, names(results))
            assert.are.equal(1, dropped)
        end)

        it("drops a last block that is never closed, however readable its title", function()
            local truncated = result(2, "Two", 3):gsub("</div>$", "")
            local results, err, dropped = search.parse_html(result(1, "One", 3) .. truncated .. footer(10))
            assert.is_nil(err)
            assert.are.same({ "One" }, names(results))
            assert.are.equal(1, dropped)
        end)

        it("drops a block cut off mid-page, and calls a page of only that drift", function()
            local whole = result(2, "Two", 3)
            local cut = whole:sub(1, whole:find("</a>", 1, true) + 3) -- ends right after the title link
            local results, err, dropped = search.parse_html(cut)
            assert.are.same({}, results)
            assert.is_true(err.drift)
            assert.are.equal(1, dropped)
        end)

        it("counts every block after one that is never closed as dropped, not guessed at", function()
            local truncated = result(1, "One", 2):gsub("</div>$", "")
            local results, err, dropped = search.parse_html(truncated .. result(2, "Two", 2) .. result(3, "Three", 2))
            assert.are.same({}, results)
            assert.is_true(err.drift)
            assert.are.equal(3, dropped)
        end)

        it("ignores the marker where it is not an element's attribute", function()
            local noise = '<style>.list-item-kata { color: red }</style>'
                .. '<script>var k = "list-item-kata";</script><!-- list-item-kata -->'
            local results, err, dropped = search.parse_html(noise)
            assert.are.same({}, results)
            assert.is_nil(err)
            assert.are.equal(0, dropped)

            results, err, dropped = search.parse_html(noise .. result(1, "One", 2) .. noise)
            assert.is_nil(err)
            assert.are.same({ "One" }, names(results))
            assert.are.equal(0, dropped)
        end)

        it("does not take a marker nested inside a block for another block", function()
            local results, err, dropped = search.parse_html(
                result(1, "One", 3, { extra = '<span class="list-item-kata-badge">New</span>' })
            )
            assert.is_nil(err)
            assert.are.equal(1, #results)
            assert.are.equal(0, dropped)
            assert.are.equal(3, #results[1].languages)
        end)

        it("bounds a block by its own element, whatever that element is", function()
            local html = result(1, "One", 2, { tag = "article", extra = "<article>nested</article>" })
                .. result(2, "Two", 2, { tag = "article", title_href = "/gone" }) .. footer(10)
            local results, err, dropped = search.parse_html(html)
            assert.is_nil(err)
            assert.are.same({ "One" }, names(results))
            assert.are.equal(1, dropped)
        end)

        -- Tag-shaped text is not markup. Comments, scripts, styles and
        -- templates hold text that merely looks like tags, and so do quoted
        -- attribute values; none of it may open a block, close one, or change
        -- how deep one is.
        describe("tag-shaped text", function()
            local TEMPLATE_COPY = '<template><div class="list-item-kata"><a href="/kata/%s">Template Kata</a></div></template>'

            local function assert_bounded(inside)
                -- An unreadable last block whose inside holds `inside`, then a
                -- footer and the close of the results container around them
                -- all: a block counted one element too deep would end at that
                -- close and take the footer in, so the footer's link must not
                -- name it, whatever `inside` says.
                local results, err, dropped = search.parse_html(
                    '<div id="results">' .. result(1, "One", 2)
                        .. unreadable_title(2, "Two", 2, { extra = inside }) .. footer(10) .. "</div>"
                )
                assert.is_nil(err, inside)
                assert.are.same({ "One" }, names(results), inside)
                assert.are.equal(1, dropped, inside)
            end

            --- A readable last block with `inside` in it is still read whole, and
            --- the footer after it is still outside.
            local function assert_reads(inside)
                local results, err, dropped = search.parse_html(
                    '<div id="results">' .. result(1, "One", 2, { extra = inside }) .. footer(10) .. "</div>"
                )
                assert.is_nil(err, inside)
                assert.are.same({ "One" }, names(results), inside)
                assert.are.equal(0, dropped, inside)
                assert.are.equal(2, #results[1].languages, inside)
            end

            it("does not count elements written inside a comment", function()
                assert_bounded("<!-- <div> -->")
                assert_bounded("<!-- <div><div> -->")
                assert_bounded("<!-- </div></div></div> --><div></div>")
                assert_reads("<!-- <div> -->")
                assert_reads("<!-- </div></div></div> -->")
            end)

            -- `<!-->` and `<!--->` are whole comments, which end at once.
            it("ends a comment where HTML does", function()
                assert_reads("<!-->")
                assert_reads("<!--->")
                assert_reads("<!----><div></div>")
            end)

            it("does not count elements written inside a script, a style or a template", function()
                assert_bounded('<script>var t = "<div>";</script>')
                assert_bounded('<script type="text/x-tmpl"><div class="row"></script>')
                assert_bounded("<style>/* <div> */ .a > .b { color: red }</style>")
                assert_bounded("<template><div><div></template>")
                assert_bounded("<template><template><div></template><div></template>")
            end)

            it("ends a script only at its own closing tag", function()
                assert_bounded('<script>var s = "</style></div></template><div>";</script>')
                assert_bounded('<style>/* </script></div> <div> */</style>')
            end)

            it("reads tag names and raw-text elements without regard to case", function()
                assert_bounded('<SCRIPT>var t = "<div>";</ScRiPt>')
                assert_bounded("<STYLE>/* <div> */</STYLE>")
                local html = result(1, "One", 2, { tag = "DIV" }):gsub("<div class", "<DIV CLASS"):gsub("</div>", "</DIV>")
                local results, err = search.parse_html(html .. footer(10))
                assert.is_nil(err)
                assert.are.same({ "One" }, names(results))
            end)

            it("ignores quoted attribute values, whatever they hold", function()
                assert_bounded('<span title="a > b <div>" data-x=\'<div class="list-item-kata">\'>x</span>')
                assert_bounded("<span title='<div>'>x</span>")
                assert_bounded('<a href="/elsewhere" title="</div></div></div>">x</a>')
                assert_reads('<span title="a > b <div>" data-x=\'<div class="list-item-kata">\'>x</span>')
            end)

            it("reads a block's own opening tag through quoted values with > and <div in them", function()
                local results, err, dropped = search.parse_html(
                    result(1, "One", 3, { open_attrs = [[data-note="Fish > Chips <div>" data-alt='x > y <div class="list-item-kata">']] })
                    .. footer(10)
                )
                assert.is_nil(err)
                assert.are.same({ "One" }, names(results))
                assert.are.equal(0, dropped)
                assert.are.equal(3, #results[1].languages)

                assert.are.same({}, (search.parse_html(footer(10) .. footer(20))))
            end)

            it("does not count self-closing or void elements toward the depth", function()
                assert_bounded("<div/>")
                assert_bounded("<div /><br><img src=x><input value='>'><hr/>")
            end)

            it("does not take a commented-out or inert block for a result", function()
                local readable_block = result(1, "One", 2)
                local commented = "<!-- " .. result(2, "Two", 2) .. " -->"
                local results, err, dropped = search.parse_html(commented .. readable_block .. commented)
                assert.is_nil(err)
                assert.are.same({ "One" }, names(results))
                assert.are.equal(0, dropped)

                -- A page whose only blocks are inert is an empty page, not drift.
                results, err, dropped = search.parse_html(commented)
                assert.are.same({}, results)
                assert.is_nil(err)
                assert.are.equal(0, dropped)
            end)

            it("does not take a block in a script, a style or a template for a result", function()
                local copy = result(3, "Template Kata", 2)
                for _, inert in ipairs({
                    "<script>var tpl = '" .. copy .. "';</script>",
                    '<script type="text/template">' .. copy .. "</script>",
                    "<style>/* " .. copy .. " */</style>",
                    "<template>" .. copy .. "</template>",
                    "<template><template>" .. copy .. "</template>" .. copy .. "</template>",
                }) do
                    local results, err, dropped = search.parse_html(inert)
                    assert.are.same({}, results, inert)
                    assert.is_nil(err, inert) -- no false drift
                    assert.are.equal(0, dropped, inert)

                    results, err, dropped = search.parse_html(inert .. result(1, "One", 2) .. inert)
                    assert.is_nil(err, inert)
                    assert.are.same({ "One" }, names(results), inert)
                    assert.are.equal(0, dropped, inert)
                end
            end)

            it("does not read a title or a language out of text that is not markup", function()
                local link = '<a href="/kata/' .. hex(9) .. '">Hidden Title</a>'
                for _, inside in ipairs({
                    "<!-- " .. link .. " -->",
                    "<script>var a = '" .. link .. "';</script>",
                    "<style>/* " .. link .. " */</style>",
                    "<template>" .. link .. "</template>",
                }) do
                    local results, err, dropped = search.parse_html(unreadable_title(2, "Two", 2, { extra = inside }))
                    assert.are.same({}, results, inside)
                    assert.is_true(err.drift, inside)
                    assert.are.equal(1, dropped, inside)
                end

                local results = search.parse_html(result(1, "One", 2, {
                    extra = '<!-- <i data-language="ghost"></i> --><template><i data-language="ghost"></i></template>',
                }))
                assert.are.equal(2, #results[1].languages)
            end)

            it("takes the marker only as a whole class name", function()
                local function parsed(class)
                    return search.parse_html(('<div class="%s"><a href="/kata/%s">Name</a></div>'):format(class, hex(1)))
                end
                for _, class in ipairs({
                    "not-list-item-kata", "list-item-katas", "list-item-kata-badge", "x-list-item-kata y", "LIST-ITEM-KATA",
                }) do
                    local results, err, dropped = parsed(class)
                    assert.are.same({}, results, class)
                    assert.is_nil(err, class)
                    assert.are.equal(0, dropped, class)
                end
                for _, class in ipairs({ "list-item-kata", "a list-item-kata", "a  list-item-kata\tb", "a\nlist-item-kata\n" }) do
                    assert.are.equal(1, #parsed(class), class)
                end
            end)

            it("does not take the marker in another attribute for the class", function()
                local html = ('<div data-class="list-item-kata" title="class=\'list-item-kata\'">'
                    .. '<a href="/kata/%s">Name</a></div>'):format(hex(1))
                local results, err, dropped = search.parse_html(html)
                assert.are.same({}, results)
                assert.is_nil(err)
                assert.are.equal(0, dropped)
            end)

            it("reads past a doctype, a processing instruction and a nameless close", function()
                local html = '<!DOCTYPE html><?xml version="1.0"?></><!-- c --></ ><![CDATA[ <div> ]]>'
                local results, err, dropped = search.parse_html(html .. result(1, "One", 2) .. html)
                assert.is_nil(err)
                assert.are.same({ "One" }, names(results))
                assert.are.equal(0, dropped)
            end)

            it("returns what it read when a comment is never closed", function()
                local html = result(1, "One", 2) .. "<!-- " .. result(2, "Two", 2) .. footer(10)
                local results, err, dropped = search.parse_html(html)
                assert.is_nil(err)
                assert.are.same({ "One" }, names(results))
                assert.are.equal(0, dropped)
            end)

            it("returns what it read when a script, a style or a template is never closed", function()
                for _, open in ipairs({ "<script>", "<style>", "<template>" }) do
                    local html = result(1, "One", 2) .. open .. result(2, "Two", 2) .. footer(10)
                    local results, err, dropped = search.parse_html(html)
                    assert.is_nil(err, open)
                    assert.are.same({ "One" }, names(results), open)
                    assert.are.equal(0, dropped, open)
                end
            end)

            it("returns what it read when a tag is cut off", function()
                for _, cut in ipairs({ '<div class="list-item-kata', '<div class="list-item-kata" data-x="oops', "<div", "<" }) do
                    local results, err, dropped = search.parse_html(result(1, "One", 2) .. cut)
                    assert.is_nil(err, cut)
                    assert.are.same({ "One" }, names(results), cut)
                    assert.are.equal(0, dropped, cut)
                end
            end)
        end)

        -- A title link is a real `<a>` whose parsed href is /kata/<id>, and
        -- its name is its text up to its own closing tag. Attributes are read
        -- by walking the tag, not by pattern over its text, so a `>` or an
        -- `href=` inside one attribute's quoted value is only that value.
        describe("title links and attributes", function()
            local function parse_link(anchor) return search.parse_html(block(anchor)) end

            it("reads a title link that has a > in a quoted attribute", function()
                local results = parse_link(('<a title="A > B" href="/kata/%s">Kata</a>'):format(SLUG))
                assert.are.equal(1, #results)
                assert.are.equal("Kata", results[1].name)
                assert.are.equal(SLUG, results[1].slug)

                results = parse_link(('<a data-x=\'>\' href="/kata/%s" title="a > b">Kata</a>'):format(SLUG))
                assert.are.equal("Kata", results[1].name)
            end)

            it("reads the text of a title through inner tags that have a > in a quoted attribute", function()
                local results = parse_link(('<a href="/kata/%s"><span title="a > b">Kata</span> Name</a>'):format(SLUG))
                assert.are.equal("Kata Name", results[1].name)
            end)

            it("does not call a page of such links drift", function()
                local link = ('<a title="A > B" href="/kata/%s">Kata</a>'):format(SLUG)
                local results, err, dropped = search.parse_html(block(link) .. block(link) .. block(link))
                assert.is_nil(err)
                assert.are.equal(3, #results)
                assert.are.equal(0, dropped)
            end)

            it("does not read an href out of another attribute's value", function()
                for _, anchor in ipairs({
                    ('<a title=\'see href="/kata/%s"\' href="/elsewhere">Related</a>'):format(SLUG),
                    ('<a data-x="href=\'/kata/%s\'" href="/elsewhere">Related</a>'):format(SLUG),
                    ('<a title="x" data-href="/kata/%s">Related</a>'):format(SLUG),
                }) do
                    local results, err, dropped = search.parse_html(block(anchor))
                    assert.are.same({}, results, anchor)
                    assert.is_true(err.drift, anchor)
                    assert.are.equal(1, dropped, anchor)
                end
            end)

            it("takes the first of a repeated href, as a browser does", function()
                local first = ('<a href="/kata/%s" href="/elsewhere">Name</a>'):format(SLUG)
                local second = ('<a href="/elsewhere" href="/kata/%s">Name</a>'):format(SLUG)
                assert.are.equal(1, #parse_link(first))
                assert.are.equal(0, #parse_link(second))
            end)

            it("reads an unquoted and a single-quoted href", function()
                assert.are.equal(SLUG, parse_link(("<a href=/kata/%s>Name</a>"):format(SLUG))[1].slug)
                assert.are.equal(SLUG, parse_link(("<a href='/kata/%s'>Name</a>"):format(SLUG))[1].slug)
                assert.are.equal(SLUG, parse_link(("<a href=/kata/%s?beta=false>Name</a>"):format(SLUG))[1].slug)
                assert.are.equal(0, #parse_link(("<a href=/kata/%s/train/python>Name</a>"):format(SLUG)))
            end)

            it("does not name a kata from an anchor that is never closed", function()
                assert.are.equal(0, #parse_link(('<a href="/kata/%s">Name'):format(SLUG)))
            end)

            it("reads languages from parsed attributes of real tags", function()
                local results = search.parse_html(result(1, "One", 2, {
                    extra = [[<i title='data-language="ghost"' data-language='real'></i>]]
                        .. [[<i data-language></i><i data-language=""></i><i DATA-LANGUAGE=bare></i>]],
                }))
                assert.are.same({ "real", "bare", "lang01", "lang02" }, results[1].languages)
            end)

            it("reads the rank from a real span, and the satisfaction from the text", function()
                local html = block(('<a href="/kata/%s">Name</a><span title="9 dan">x</span>'
                    .. '<i data-tippy-content="Satisfaction Rating: 89%% of users">y</i>'):format(SLUG))
                local entry = search.parse_html(html)[1]
                assert.are.equal("6 kyu", entry.rank_name)
                assert.are.equal(-6, entry.rank_id)
                assert.are.equal(89, entry.satisfaction)
            end)
        end)

        -- RCDATA: what is between <textarea> or <title> and its closing tag is
        -- text, however much it looks like markup.
        describe("textarea and title", function()
            it("does not take a block in a textarea or a title for a result", function()
                local copy = result(3, "Textarea Kata", 2)
                for _, wrap in ipairs({ "<textarea>%s</textarea>", "<title>%s</title>", "<TEXTAREA>%s</TEXTAREA>" }) do
                    local inert = wrap:format(copy)
                    local results, err, dropped = search.parse_html(inert)
                    assert.are.same({}, results, inert)
                    assert.is_nil(err, inert) -- no false drift
                    assert.are.equal(0, dropped, inert)

                    results, err, dropped = search.parse_html(inert .. result(1, "One", 2) .. inert)
                    assert.is_nil(err, inert)
                    assert.are.same({ "One" }, names(results), inert)
                    assert.are.equal(0, dropped, inert)
                end
            end)

            it("does not read a title out of a textarea inside a block", function()
                local link = '<a href="/kata/' .. hex(9) .. '">Hidden Title</a>'
                local results, err, dropped = search.parse_html(
                    unreadable_title(2, "Two", 2, { extra = "<textarea>" .. link .. "</textarea>" })
                )
                assert.are.same({}, results)
                assert.is_true(err.drift)
                assert.are.equal(1, dropped)
            end)

            it("does not count elements written inside a textarea toward a block's depth", function()
                local results, err, dropped = search.parse_html(
                    '<div id="results">' .. result(1, "One", 2, { extra = "<textarea><div><div></textarea>" })
                        .. footer(10) .. "</div>"
                )
                assert.is_nil(err)
                assert.are.same({ "One" }, names(results))
                assert.are.equal(0, dropped)
            end)

            it("returns what it read when one is never closed", function()
                for _, open in ipairs({ "<textarea>", "<title>" }) do
                    local results, err, dropped = search.parse_html(result(1, "One", 2) .. open .. result(2, "Two", 2))
                    assert.is_nil(err, open)
                    assert.are.same({ "One" }, names(results), open)
                    assert.are.equal(0, dropped, open)
                end
            end)
        end)

        -- One pass over the page: a block is scanned once, and a block that
        -- never closes does not send every block after it back over the rest
        -- of the page. A generous bound, only to catch a rescan per block.
        it("reads a large page, closed or not, in a single pass", function()
            local uv = vim.uv or vim.loop
            local html = {}
            for n = 1, 2000 do html[#html + 1] = result(n, "Kata " .. n, 2) end
            local closed = table.concat(html)

            local started = uv.hrtime()
            local results, err, dropped = search.parse_html(closed)
            assert.is_nil(err)
            assert.are.equal(2000, #results)
            assert.are.equal(0, dropped)
            assert.is_true((uv.hrtime() - started) / 1e9 < 2, "closed page took too long")

            html[1] = html[1]:gsub("</div>$", "")
            started = uv.hrtime()
            local _
            _, err, dropped = search.parse_html(table.concat(html))
            assert.is_true(err.drift)
            assert.are.equal(2000, dropped)
            assert.is_true((uv.hrtime() - started) / 1e9 < 2, "unclosed page took too long")
        end)

        it("does not count a differently named element for the block's own", function()
            local results, err, dropped = search.parse_html(
                result(1, "One", 2, { extra = "<divider><div-icon></div-icon>" })
            )
            assert.is_nil(err)
            assert.are.same({ "One" }, names(results))
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
