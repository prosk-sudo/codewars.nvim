local md = require("codewars-ui.markdown")

describe("markdown.from_html blockquote", function()
    it("turns a hint blockquote into a real markdown quote", function()
        local out = md.from_html("Hint:\n<blockquote>The length is not the number of characters</blockquote>")
        assert.truthy(out:match("> The length is not the number of characters"))
        assert.is_nil(out:find("<blockquote>", 1, true))
        assert.is_nil(out:find("</blockquote>", 1, true))
    end)

    it("quotes every line of a multi-line blockquote", function()
        local out = md.from_html("<blockquote>first line\nsecond line</blockquote>")
        assert.truthy(out:match("> first line"))
        assert.truthy(out:match("> second line"))
    end)

    it("converts emphasis nested inside a blockquote", function()
        local out = md.from_html("<blockquote>be <b>careful</b> here</blockquote>")
        assert.truthy(out:match("> be %*%*careful%*%* here"))
    end)
end)

describe("markdown.from_html generic type parameters", function()
    -- The reason this is an allowlist and not a tag stripper: descriptions are
    -- full of things that look like tags but are code.
    it("leaves List<string> and vector<T> untouched", function()
        local src = "Return a List<string> built from a vector<T>."
        assert.are.equal(src, md.from_html(src))
    end)

    it("leaves an unknown tag alone rather than stripping it", function()
        local src = "compare with <=> or <foo> here"
        assert.are.equal(src, md.from_html(src))
    end)

    -- Regression: `<i[^>]*>` matched `<int, string>`, paired with a real
    -- `</i>` later in the text, and deleted everything between the two.
    it("does not let a generic starting with a tag name swallow real markup", function()
        local src = "Build a Dictionary<int, string> then see <i>note</i> below."
        assert.are.equal("Build a Dictionary<int, string> then see *note* below.", md.from_html(src))
    end)

    it("does not let <bool> pair with a later closing b tag", function()
        local src = "Return List<bool> and read <b>this</b>."
        assert.are.equal("Return List<bool> and read **this**.", md.from_html(src))
    end)

    it("still converts a tag that carries attributes", function()
        assert.are.equal("**x**", md.from_html('<b class="hl">x</b>'))
        assert.truthy(md.from_html('<blockquote cite="x">hint</blockquote>'):match("> hint"))
    end)

    it("does not rewrite HTML inside a fenced code block", function()
        local src = "Parse this:\n```\n<b>bold</b> and <div>x</div>\n```\n"
        local out = md.from_html(src)
        assert.truthy(out:find("<b>bold</b>", 1, true))
        assert.truthy(out:find("<div>x</div>", 1, true))
    end)

    it("does not rewrite HTML inside inline code", function()
        local out = md.from_html("the `<br>` tag ends a line")
        assert.truthy(out:find("`<br>`", 1, true))
    end)
end)

describe("markdown.from_html inline and block tags", function()
    it("maps br to a newline and hr to a rule", function()
        assert.truthy(md.from_html("a<br>b"):match("a\nb"))
        assert.truthy(md.from_html("a<br />b"):match("a\nb"))
        assert.truthy(md.from_html("a<hr>b"):match("%-%-%-"))
    end)

    it("maps bold, italic and code", function()
        assert.truthy(md.from_html("<b>x</b>"):match("^%*%*x%*%*"))
        assert.truthy(md.from_html("<strong>x</strong>"):match("^%*%*x%*%*"))
        assert.truthy(md.from_html("<i>x</i>"):match("^%*x%*"))
        assert.truthy(md.from_html("<em>x</em>"):match("^%*x%*"))
        assert.truthy(md.from_html("<code>x</code>"):match("^`x`"))
    end)

    it("maps links and images, keeping the target", function()
        assert.are.equal("[docs](http://e.com)", md.from_html('<a href="http://e.com">docs</a>'))
        assert.are.equal("![](http://e.com/i.png)", md.from_html('<img src="http://e.com/i.png">'))
        assert.are.equal("![tree](http://e.com/i.png)",
            md.from_html('<img alt="tree" src="http://e.com/i.png">'))
    end)

    it("reads single-quoted and unquoted attributes too", function()
        assert.are.equal("[docs](http://e.com)", md.from_html("<a href='http://e.com'>docs</a>"))
        assert.are.equal("![](http://e.com/i.png)", md.from_html("<img src='http://e.com/i.png'>"))
        assert.are.equal("![](http://e.com/i.png)", md.from_html("<img src=http://e.com/i.png>"))
        assert.are.equal("![tree](i.png)", md.from_html("<img alt='tree' src='i.png'>"))
    end)

    it("tolerates attribute order and extra attributes", function()
        assert.are.equal("![tree](i.png)", md.from_html('<img src="i.png" alt="tree">'))
        assert.are.equal("[docs](u)", md.from_html('<a class="x" href="u" target="_blank">docs</a>'))
    end)

    it("does not read href out of a lookalike attribute", function()
        local src = '<a data-href="nope">text</a>'
        assert.are.equal(src, md.from_html(src))
    end)

    it("unwraps center/div/span but keeps their content", function()
        local out = md.from_html("<center>middle</center>")
        assert.are.equal("middle", vim.trim(out))
        assert.is_nil(out:find("<center>", 1, true))
    end)

    it("maps list items to bullets", function()
        local out = md.from_html("<ul><li>one</li><li>two</li></ul>")
        assert.truthy(out:match("%- one"))
        assert.truthy(out:match("%- two"))
        assert.is_nil(out:find("<li>", 1, true))
    end)

    it("maps sup and sub", function()
        assert.truthy(md.from_html("2<sup>3</sup>"):match("2%^3"))
        assert.truthy(md.from_html("x<sub>i</sub>"):match("x_i"))
    end)

    it("wraps a pre block in a fence and keeps its blank lines", function()
        local out = md.from_html("<pre>def a():\n    pass\n\ndef b():\n    pass</pre>")
        assert.truthy(out:find("```", 1, true))
        -- The blank line between the two defs must survive the whitespace
        -- collapse that runs at the end of the conversion.
        assert.truthy(out:find("pass\n\ndef b", 1, true))
    end)

    it("does not convert markup inside a pre block", function()
        local out = md.from_html("<pre><b>x</b></pre>")
        assert.truthy(out:find("<b>x</b>", 1, true))
    end)
end)

describe("markdown.from_html passthrough", function()
    it("returns plain markdown unchanged", function()
        local src = "# Title\n\nSome **bold** text and a `snippet`.\n\n- a\n- b\n"
        assert.are.equal(src, md.from_html(src))
    end)

    it("handles nil and empty input", function()
        assert.are.equal("", md.from_html(nil))
        assert.are.equal("", md.from_html(""))
    end)

    it("leaves no sentinel behind", function()
        local out = md.from_html("`code` and <b>bold</b> and ```\nfence\n```")
        assert.is_nil(out:find("CWMD", 1, true))
    end)
end)

-- `paired` used to match `<tag>(.-)</tag>`: the first closing tag ended the
-- construct, so a same-name tag nested inside it left the outer one's tail as
-- literal markup in the rendered description.
describe("markdown.from_html nested same-name tags", function()
    local function lines(text)
        return vim.split(vim.trim(text), "\n", { plain = true })
    end

    it("renders a nested blockquote as > and > > lines", function()
        local out = md.from_html("<blockquote>a<blockquote>b</blockquote>c</blockquote>")
        assert.are.same({ "> a", ">", "> > b", ">", "> c" }, lines(out))
        assert.is_nil(out:find("blockquote", 1, true))
    end)

    it("nests a blockquote three deep", function()
        local out = md.from_html(
            "<blockquote>a<blockquote>b<blockquote>c</blockquote></blockquote></blockquote>")
        assert.are.same({ "> a", ">", "> > b", "> >", "> > > c" }, lines(out))
    end)

    it("pairs an outer opener that has attributes with the inner one that has none", function()
        local out = md.from_html('<blockquote class="hint">a<blockquote>b</blockquote></blockquote>')
        assert.are.same({ "> a", ">", "> > b" }, lines(out))
        out = md.from_html('<blockquote>a<blockquote cite="x">b</blockquote>c</blockquote>')
        assert.are.same({ "> a", ">", "> > b", ">", "> c" }, lines(out))
    end)

    it("converts the markup inside the inner and the outer construct", function()
        local out = md.from_html(
            "<blockquote>be <b>careful</b><blockquote>inner <i>note</i></blockquote></blockquote>")
        assert.are.same({ "> be **careful**", ">", "> > inner *note*" }, lines(out))
    end)

    it("keeps every item of a nested list", function()
        local out = md.from_html("<ul><li>a<ul><li>b</li><li>c</li></ul></li><li>d</li></ul>")
        for _, item in ipairs({ "a", "b", "c", "d" }) do
            assert.truthy(out:find("- " .. item, 1, true), "missing item " .. item)
        end
        assert.is_nil(out:find("<li", 1, true))
        assert.is_nil(out:find("</li>", 1, true))
        assert.is_nil(out:find("<ul", 1, true))
        assert.is_nil(out:find("</ul>", 1, true))
        -- Document order survives.
        assert.is_true(out:find("- a", 1, true) < out:find("- b", 1, true))
        assert.is_true(out:find("- c", 1, true) < out:find("- d", 1, true))
    end)

    it("handles a string replacement (%1) through nesting, with or without attributes", function()
        assert.are.equal("**x**y**z**", md.from_html("<b>x<b>y</b>z</b>"))
        assert.are.equal("*x*y*z*", md.from_html('<i class="a">x<i>y</i>z</i>'))
        assert.are.equal("**x**y**z**", md.from_html('<b>x<b class="n">y</b>z</b>'))
    end)

    it("still converts siblings, in both replacement forms", function()
        assert.are.equal("**x** and **y**", md.from_html("<b>x</b> and <b>y</b>"))
        local out = md.from_html("<blockquote>one</blockquote>between<blockquote>two</blockquote>")
        assert.are.same({ "> one", "", "between", "", "> two" }, lines(out))
        local pre = md.from_html("<pre>a</pre> text <pre>b</pre>")
        assert.are.equal(4, select(2, pre:gsub("```", "")))
        assert.truthy(pre:find("text", 1, true))
    end)

    it("does not count a longer tag name as a nested opener", function()
        assert.are.equal("**a<bool>c</bool>**", md.from_html("<b>a<bool>c</bool></b>"))
    end)

end)

-- Every closing tag copies the converted text inside it, so the work grows
-- with nesting depth times length: a description of tens of thousands of
-- nested tags used to stall the render. Nesting deeper than MAX_NEST_DEPTH
-- (64, in markdown.lua) is left as written; real descriptions nest a few
-- levels at most.
describe("markdown.from_html nesting depth cap", function()
    local CAP = 64

    local function bold(depth, inner)
        return ("<b>"):rep(depth) .. inner .. ("</b>"):rep(depth)
    end

    it("converts nesting up to the cap in full", function()
        assert.are.equal(("**"):rep(CAP) .. "x" .. ("**"):rep(CAP), md.from_html(bold(CAP, "x")))
        local out = md.from_html(("<blockquote>"):rep(CAP) .. "x" .. ("</blockquote>"):rep(CAP))
        assert.are.equal(("> "):rep(CAP) .. "x", vim.trim(out))
    end)

    it("leaves the one tag past the cap as written, paired with its own closer", function()
        assert.are.equal(
            ("**"):rep(CAP) .. "<b>x</b>" .. ("**"):rep(CAP),
            md.from_html(bold(CAP + 1, "x")))
        local out = md.from_html(("<blockquote>"):rep(CAP + 1) .. "x" .. ("</blockquote>"):rep(CAP + 1))
        assert.are.equal(("> "):rep(CAP) .. "<blockquote>x</blockquote>", vim.trim(out))
    end)

    it("leaves every tag past the cap as written, however many there are", function()
        local extra = 19936
        local out = md.from_html(bold(CAP + extra, "x"))
        assert.are.equal(
            ("**"):rep(CAP) .. ("<b>"):rep(extra) .. "x" .. ("</b>"):rep(extra) .. ("**"):rep(CAP),
            out)
    end)

    it("converts what follows a too-deep run as if the run had closed", function()
        local out = md.from_html(bold(CAP + 6, "x") .. " and " .. bold(1, "y"))
        assert.are.equal(
            ("**"):rep(CAP) .. ("<b>"):rep(6) .. "x" .. ("</b>"):rep(6) .. ("**"):rep(CAP) .. " and **y**",
            out)
    end)

    it("renders tens of thousands of nested tags without stalling", function()
        local uv = vim.uv or vim.loop
        local src = bold(100000, "x")
        local started = uv.hrtime()
        local out = md.from_html(src)
        local elapsed_ms = (uv.hrtime() - started) / 1e6
        assert.are.equal(("**"):rep(CAP), out:sub(1, 2 * CAP))
        -- Uncapped, this is quadratic in the depth (seconds); capped it is a
        -- fraction of a second. The bound leaves generous room for a slow
        -- machine; the structural specs above are the exact guard.
        assert.is_true(elapsed_ms < 1500, ("took %d ms"):format(elapsed_ms))
    end)
end)

-- Real descriptions are not always balanced. Whatever the markup, the
-- conversion must finish, never raise, and leave a tag it cannot pair as text.
describe("markdown.from_html unbalanced tags", function()
    local function lines(text)
        return vim.split(vim.trim(text), "\n", { plain = true })
    end

    it("leaves an unclosed tag as text", function()
        for _, src in ipairs({
            "<b>never closed",
            "<blockquote>never closed",
            "<li>one<li>two",
            '<b class="x">never closed',
        }) do
            assert.are.equal(src, md.from_html(src))
        end
    end)

    it("leaves a closing tag with no opener as text", function()
        for _, src in ipairs({ "a</b>b", "</blockquote>", "x</li>y" }) do
            assert.are.equal(src, md.from_html(src))
        end
        assert.are.equal("</b>**x**", md.from_html("</b><b>x</b>"))
        assert.are.equal("**x**</b>", md.from_html("<b>x</b></b>"))
    end)

    it("converts the balanced inner pair when the outer opener has no closer", function()
        assert.are.equal("<b>a**b**", md.from_html("<b>a<b>b</b>"))
        local out = md.from_html("<blockquote>a<blockquote>b</blockquote>")
        assert.are.same({ "<blockquote>a", "", "> b" }, lines(out))
    end)

    it("converts the balanced pair when the extra closer comes first or last", function()
        assert.are.equal("**a**b</b>", md.from_html("<b>a</b>b</b>"))
        local out = md.from_html("<blockquote>a</blockquote>b</blockquote>")
        assert.are.same({ "> a", "", "b</blockquote>" }, lines(out))
    end)

    it("finishes on a long run of unmatched tags", function()
        local openers = ("<b>"):rep(5000)
        assert.are.equal(openers, md.from_html(openers))
        local closers = ("</b>"):rep(5000)
        assert.are.equal(closers, md.from_html(closers))
        local quotes = ("<blockquote>"):rep(3000) .. "x"
        assert.are.equal(quotes, md.from_html(quotes))
        -- More openers than closers: the extra ones stay, the pairs convert.
        local half = md.from_html(("<b>"):rep(40) .. "x" .. ("</b>"):rep(20))
        assert.are.equal(("<b>"):rep(20) .. ("**"):rep(20) .. "x" .. ("**"):rep(20), half)
        -- Here every closer pairs with an opener past the depth cap (the 64
        -- outer openers are never closed), so nothing converts.
        local deep = ("<b>"):rep(2000) .. "x" .. ("</b>"):rep(1000)
        assert.are.equal(deep, md.from_html(deep))
    end)
end)
