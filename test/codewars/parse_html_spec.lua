describe("solutions.parse_html", function()
    local solutions = require("codewars.api.solutions")

    it("extracts code from valid HTML", function()
        local html = [[
<div>
  <pre><code>def multiply(a, b):
    return a * b</code></pre>
  <pre><code>def solution(a, b):
    return a * b</code></pre>
</div>
]]
        local result = solutions.parse_html(html, "python")
        -- First block is skipped (test fixture) when multiple exist
        assert.are.equal(1, #result)
        assert.truthy(result[1]:find("def solution"))
    end)

    describe("empty_reason", function()
        it("beta kata pending approval", function()
            local level, msg = solutions.empty_reason("<html></html>", true)
            assert.are.equal("info", level)
            assert.truthy(msg:match("beta"))
        end)

        it("locked page means completion not registered", function()
            local level, msg = solutions.empty_reason("<a>Unlock Solutions</a><span>Forfeit eligibility</span>", false)
            assert.are.equal("warn", level)
            assert.truthy(msg:match("locked"))
        end)

        it("empty Vue template means genuinely no solutions", function()
            local level, msg = solutions.empty_reason('<pre v-else-if="solution"><code v-text="solution"></code></pre>', nil)
            assert.are.equal("info", level)
            assert.truthy(msg:match("No community solutions"))
        end)

        it("unrecognized page is a drift warning", function()
            local level, msg = solutions.empty_reason("<html><body>???</body></html>", nil)
            assert.are.equal("warn", level)
            assert.truthy(msg:match("changed their HTML"))
        end)
    end)

    it("returns empty for a beta kata's client-rendered page (empty Vue template)", function()
        -- Verified live 2026-07-03: beta solutions pages ship exactly one
        -- empty <pre><code v-text="solution"> template and no server HTML.
        local html = '<pre class="p-2" v-else-if="solution"><code v-text="solution" data-language="python"></code></pre>'
        local result = solutions.parse_html(html, "python")
        assert.are.equal(0, #result)
    end)

    it("keeps single code block (no fixture skip)", function()
        local html = '<pre><code>def solution(a, b):\n    return a * b</code></pre>'
        local result = solutions.parse_html(html, "python")
        assert.are.equal(1, #result)
        assert.truthy(result[1]:find("def solution"))
    end)

    it("unescapes HTML entities", function()
        local html = '<pre><code>if a &lt; b &amp;&amp; c &gt; d:\n    return &quot;hello&quot;</code></pre>'
        local result = solutions.parse_html(html, "python")
        assert.are.equal(1, #result)
        assert.truthy(result[1]:find("if a < b"))
        assert.truthy(result[1]:find('return "hello"'))
    end)

    it("unescapes &#39; and &#x27; to single quote", function()
        local html = "<pre><code>s = &#39;hello&#x27;</code></pre>"
        local result = solutions.parse_html(html, "python")
        assert.are.equal(1, #result)
        assert.truthy(result[1]:find("s = 'hello'"))
    end)

    it("returns empty for no code blocks", function()
        local html = "<div>No code here</div>"
        local result = solutions.parse_html(html, "python")
        assert.are.equal(0, #result)
    end)

    it("filters out short code blocks (<= 10 chars)", function()
        local html = '<pre><code>short</code></pre>'
        local result = solutions.parse_html(html, "python")
        assert.are.equal(0, #result)
    end)

    it("handles empty HTML", function()
        local result = solutions.parse_html("", "python")
        assert.are.equal(0, #result)
    end)

    it("skips first block when multiple exist", function()
        local html = [[
<pre><code>import Test from "test-framework"</code></pre>
<pre><code>function solution_one(a, b) { return a * b; }</code></pre>
<pre><code>function solution_two(a, b) { return a + b; }</code></pre>
]]
        local result = solutions.parse_html(html, "javascript")
        assert.are.equal(2, #result)
        assert.truthy(result[1]:find("solution_one"))
        assert.truthy(result[2]:find("solution_two"))
    end)
end)

-- Structured parse: one group wrapper per solution carrying the authors,
-- the Best Practices / Clever counts and the comments component, whose
-- data is an HTML-escaped JSON blob. Shape verified live 2026-08-23
-- against /kata/563e320cee5dddcf77000158/solutions/python.
describe("solutions.parse", function()
    local solutions = require("codewars.api.solutions")

    -- The comments JSON exactly as the site escapes it into the attribute.
    local COMMENTS_JSON = table.concat({
        "{&quot;comments&quot;:[{&quot;id&quot;:&quot;c1&quot;,&quot;masked&quot;:null,&quot;votes_score&quot;:2,",
        "&quot;markdown&quot;:&quot;Nice &amp; clean, `x // 2`&quot;,",
        "&quot;created_at_datetime&quot;:&quot;2026-06-05T09:15:41.560+0000&quot;,&quot;nest_level&quot;:0,",
        "&quot;user&quot;:{&quot;username&quot;:&quot;alice&quot;,&quot;rank_name&quot;:&quot;1 kyu&quot;},",
        "&quot;comments&quot;:[{&quot;id&quot;:&quot;c2&quot;,&quot;masked&quot;:true,&quot;votes_score&quot;:0,",
        "&quot;markdown&quot;:&quot;not in python 2&quot;,",
        "&quot;created_at_datetime&quot;:&quot;2026-06-06T10:00:00.000+0000&quot;,&quot;nest_level&quot;:1,",
        "&quot;user&quot;:{&quot;username&quot;:&quot;bob&quot;,&quot;rank_name&quot;:&quot;4 kyu&quot;},",
        "&quot;comments&quot;:[]}]}],&quot;totalComments&quot;:2,&quot;spoilerFlag&quot;:true}",
    })

    local function group(id, code, bp, clever, comments_json, authors)
        return table.concat({
            ('<div class="js-result-group px-4" data-controller="solution-group" data-solution-group-group-id-value="%s" id="%s">'):format(id, id),
            '<h6 class="solution-group-users-list my-4"><i class="icon-moon-users "></i>',
            authors or '<a class="font-semibold" href="/users/JustyFY">JustyFY</a><span>, </span><a href="/users/Mr.%20Meeseeks">Mr. Meeseeks</a><span> (+ 4592)</span>',
            '<div class="clearfix"></div></h6>',
            ('<pre class="p-2"><code data-language="python">%s</code></pre>'):format(code),
            '<ul class="piped-text mt-4"><li><ul class="vote-labels" data-vote-name="solution-solution_group" data-vote-ref-id="' .. id .. '">',
            ('<li><a class="vote-label" data-label="best_practice"><i class="icon-moon-up "></i>Best Practices<span>%d</span></a></li>'):format(bp),
            ('<li><a class="vote-label" data-label="clever"><i class="icon-moon-up "></i>Clever<span>%d</span></a></li></ul></li>'):format(clever),
            '<li><a class="js-show-comments"><span v-text="totalComments">0</span></a></li></ul>',
            '<div class="comments-list-component" v-scope data-view-data="' .. (comments_json or "{&quot;comments&quot;:[],&quot;totalComments&quot;:0}") .. '">',
            '<div class="comments"></div></div></div>',
        })
    end

    local PAGE = table.concat({
        '<html><body><div class="mt-1 mb-3" data-id="563e320cee5dddcf77000158">',
        '<pre><code>import codewars_test as test  # the fixture block, NOT a solution</code></pre></div>',
        '<div id="solutions_list">',
        group("56475c08593a1941660000b2", "def get_average(marks):\n    return sum(marks) // len(marks)", 487, 168, COMMENTS_JSON),
        group("5647b97c8d4acb805100004c", "def get_average(marks):\n    return int(sum(marks) / len(marks))", 12, 3, nil,
            '<a href="/users/solo">solo</a>'),
        "</div></body></html>",
    })

    it("returns one entry per solution group, never the fixture block", function()
        local result = solutions.parse(PAGE, "python")
        assert.are.equal(2, #result)
        assert.are.equal("56475c08593a1941660000b2", result[1].id)
        assert.truthy(result[1].code:find("// len", 1, true))
        assert.truthy(result[2].code:find("int(sum", 1, true))
        for _, s in ipairs(result) do
            assert.is_nil(s.code:find("codewars_test", 1, true))
        end
    end)

    it("reads the Best Practices and Clever counts", function()
        local result = solutions.parse(PAGE, "python")
        assert.are.same({ best_practice = 487, clever = 168 }, result[1].votes)
        assert.are.same({ best_practice = 12, clever = 3 }, result[2].votes)
    end)

    it("lists the authors and the '+ N' overflow", function()
        local result = solutions.parse(PAGE, "python")
        assert.are.same({ "JustyFY", "Mr. Meeseeks" }, result[1].authors)
        assert.are.equal(4592, result[1].extra_authors)
        assert.are.same({ "solo" }, result[2].authors)
        assert.are.equal(0, result[2].extra_authors)
    end)

    it("decodes the embedded comments, flattened depth-first", function()
        local result = solutions.parse(PAGE, "python")
        local c = result[1].comments
        assert.are.equal(2, result[1].total_comments)
        assert.are.equal(2, #c)
        assert.are.same({
            id = "c1", author = "alice", rank = "1 kyu", body = "Nice & clean, `x // 2`",
            created = "2026-06-05", score = 2, depth = 0, masked = false,
        }, c[1])
        assert.are.equal("bob", c[2].author)
        assert.are.equal(1, c[2].depth)
        assert.is_true(c[2].masked)
        assert.are.equal("not in python 2", c[2].body)
    end)

    it("a solution with no comments component has an empty list, not an error", function()
        local result = solutions.parse(PAGE, "python")
        assert.are.same({}, result[2].comments)
        assert.are.equal(0, result[2].total_comments)
    end)

    it("falls back to the bare code scan when the page has no group wrappers", function()
        local html = "<pre><code>fixture fixture</code></pre><pre><code>def solution(): return 1</code></pre>"
        local result = solutions.parse(html, "python")
        assert.are.equal(1, #result)
        assert.truthy(result[1].code:find("def solution", 1, true))
        assert.are.same({}, result[1].comments)
        assert.are.same({ best_practice = 0, clever = 0 }, result[1].votes)
    end)

    it("returns empty for the beta kata's empty Vue template", function()
        local html = '<pre v-else-if="solution"><code v-text="solution" data-language="python"></code></pre>'
        assert.are.equal(0, #solutions.parse(html, "python"))
    end)

    -- Codewars takes 5-7 s to render a popular kata's solutions page
    -- (server time, measured). Reopening within the session must not pay
    -- that again.
    describe("fetch session cache", function()
        local page = require("codewars.api.page")
        local real_fetch = page.fetch
        local fetches

        before_each(function()
            fetches = 0
            solutions.invalidate()
            page.fetch = function(_, cb)
                fetches = fetches + 1
                cb(PAGE)
            end
        end)
        after_each(function()
            page.fetch = real_fetch
            solutions.invalidate()
        end)

        it("serves the second fetch of the same kata/language from memory", function()
            local a, b
            solutions.fetch("kid", "python", function(r) a = r end)
            solutions.fetch("kid", "python", function(r) b = r end)
            assert.are.equal(1, fetches)
            assert.are.equal(2, #a)
            assert.are.equal(a, b)
        end)

        it("is keyed by language, and force bypasses it", function()
            solutions.fetch("kid", "python", function() end)
            solutions.fetch("kid", "ruby", function() end)
            assert.are.equal(2, fetches)
            solutions.fetch("kid", "python", function() end, { force = true })
            assert.are.equal(3, fetches)
        end)

        it("expires after the TTL", function()
            solutions.fetch("kid", "python", function() end)
            solutions._cache["kid/python"].at = os.time() - solutions.CACHE_TTL_S - 1
            solutions.fetch("kid", "python", function() end)
            assert.are.equal(2, fetches)
        end)

        it("does not cache a page that yielded no solutions", function()
            page.fetch = function(_, cb)
                fetches = fetches + 1
                cb('<pre v-else-if="solution"><code v-text="solution"></code></pre>')
            end
            solutions.fetch("kid", "python", function() end)
            solutions.fetch("kid", "python", function() end)
            assert.are.equal(2, fetches)
        end)
    end)
end)
