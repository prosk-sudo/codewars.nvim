-- The tokenizer yields real tags only: what a browser would split the page
-- into, so that counting an element's opens and closes counts nothing that
-- merely looks like a tag.
describe("api.htmltags", function()
    local htmltags = require("codewars.api.htmltags")

    --- "name" for an opening tag, "/name" for a closing one.
    local function names(html)
        local tags = htmltags.scan(html)
        return vim.tbl_map(function(tag) return (tag.close and "/" or "") .. tag.name end, tags)
    end

    it("reads opening and closing tags with their positions", function()
        local html = 'ab<div class="x y">cd</div>'
        local tags = htmltags.scan(html)
        assert.are.equal(2, #tags)
        assert.are.same(
            { name = "div", close = false, start = 3, finish = 19, attrs = { class = "x y" }, empty = false },
            tags[1]
        )
        assert.are.equal("</div>", html:sub(tags[2].start, tags[2].finish))
        assert.is_true(tags[2].close)
    end)

    it("lower-cases names and reads the class attribute in any case", function()
        local tags = htmltags.scan("<DIV CLASS='A b'></DIV>")
        assert.are.equal("div", tags[1].name)
        assert.are.equal("A b", tags[1].attrs.class)
        assert.are.equal("div", tags[2].name)
    end)

    -- Attributes are read by walking the tag once, so text in one attribute's
    -- value is never read as another attribute.
    describe("attributes", function()
        local function attrs(html) return htmltags.scan(html)[1].attrs end

        it("reads double-quoted, single-quoted, unquoted and bare attributes", function()
            assert.are.same(
                { a = "1 > 2", b = "x y", c = "z/w", d = "", e = "" },
                attrs([[<p a="1 > 2" b='x y' c=z/w d e=>]])
            )
        end)

        it("lower-cases the names and keeps the values as written", function()
            assert.are.same({ class = "A B", ["data-x"] = "Y" }, attrs("<p CLASS=\"A B\" Data-X='Y'>"))
        end)

        it("takes the first of a repeated attribute, as a browser does", function()
            assert.are.equal("a", attrs('<p class="a" class="b">').class)
            assert.are.equal("/one", attrs('<a href=/one href="/two">').href)
            assert.are.equal("", attrs("<p class class=b>").class)
        end)

        it("never reads text in a value as another attribute", function()
            local found = attrs([[<a title='see href="/kata/x"' data-y="class='z'" href="/real">]])
            assert.are.same({ title = 'see href="/kata/x"', ["data-y"] = "class='z'", href = "/real" }, found)
            assert.is_nil(attrs("<p data-class=\"a\" title=\"class='b'\">").class)
        end)

        it("starts a quote only after an equals sign, with space allowed around it", function()
            assert.are.same({ ["it's"] = "", b = "x" }, attrs("<a it's b = 'x'>"))
            assert.are.same({ b = "it's" }, attrs("<a b=it's>"))
        end)

        -- A browser reads character references in a value; a parser that does
        -- not reads `href="&#47;kata..."` as a different link.
        it("decodes character references in values: named, decimal and hex", function()
            assert.are.same(
                { href = "/kata/a?b=1&c", class = "x y", title = "A > B" },
                attrs([[<a href="&#47;kata&#x2F;a&quest;b&equals;1&amp;c" class='x&#32;y' title=A&#x20;&gt;&#32;B>]])
            )
        end)

        it("decodes a value once, and leaves an unknown reference as written", function()
            assert.are.same(
                { a = "&#47;", b = "x&bogus;y", c = "&#xD800;&#;" },
                attrs([[<p a="&amp;#47;" b='x&bogus;y' c="&#xD800;&#;">]])
            )
        end)

        it("does not decode a name, or let a reference end a tag or a value", function()
            local tags = htmltags.scan([[<p a&#98;="1" b="&quot;" c='&#39;' d="&#62;">x</p>]])
            assert.are.same({ ["a&#98;"] = "1", b = '"', c = "'", d = ">" }, tags[1].attrs)
            assert.are.same({ "p", "/p" }, names([[<p a&#98;="1" b="&quot;" c='&#39;' d="&#62;">x</p>]]))
        end)

        it("has no attributes for a closing tag or a tag without any", function()
            assert.are.same({}, htmltags.scan("<p></p>")[1].attrs)
            assert.are.same({}, htmltags.scan("<p></p>")[2].attrs)
        end)
    end)

    it("marks void and self-closing elements as empty", function()
        local tags = htmltags.scan("<br><img src=x><div/><div /><span></span><input value='>'>")
        local empty = vim.tbl_map(function(tag) return tag.empty end, tags)
        assert.are.same({ true, true, true, true, false, false, true }, empty)
    end)

    it("skips comments whole, and one never closed to the end", function()
        assert.are.same({ "p", "/p" }, names("<p><!-- <div> --></p>"))
        assert.are.same({ "p" }, names("<p><!-- <div> </p>"))
    end)

    -- `<!-->` and `<!--->` are whole comments: the tags between them are real.
    it("ends a comment where HTML does", function()
        assert.are.same({ "p", "div", "/div", "/p" }, names("<p><!--><div></div><!---></p>"))
        assert.are.same({ "p", "/p" }, names("<p><!----><!-- a -- b --></p>"))
    end)

    it("skips a script and a style as raw text, up to their own closing tag", function()
        assert.are.same({ "p", "/p" }, names('<p><script>var s = "<div></style>";</script></p>'))
        assert.are.same({ "p", "/p" }, names("<p><style>a > b { } /* <div> */</style></p>"))
        assert.are.same({ "p", "/p" }, names("<p><SCRIPT>x = '<div>';</ScRiPt ></p>"))
        assert.are.same({ "p" }, names("<p><script>never <div> closed</p>"))
    end)

    -- RCDATA: the browser shows what is between the tags as text.
    it("skips a textarea and a title as raw text too", function()
        assert.are.same({ "p", "/p" }, names('<p><textarea><div class="list-item-kata"></textarea></p>'))
        assert.are.same({ "p", "/p" }, names("<p><title><div></title></p>"))
        assert.are.same({ "p", "/p" }, names("<p><TEXTAREA><b></TextArea ></p>"))
        assert.are.same({ "p" }, names("<p><textarea><div>never closed</p>"))
        assert.are.same({ "p" }, names("<p><title><div>never closed</p>"))
    end)

    -- The rest of HTML's raw text and escapable raw text elements. `noscript`
    -- is read as it is when scripts run.
    it("skips xmp, iframe, noembed, noframes and noscript as raw text", function()
        for _, element in ipairs({ "xmp", "iframe", "noembed", "noframes", "noscript" }) do
            local open, close = "<" .. element .. ">", "</" .. element .. ">"
            assert.are.same({ "p", "/p" }, names("<p>" .. open .. '<div class="a"><!-- ' .. close .. "</p>"), element)
            assert.are.same({ "p", "/p" }, names("<p>" .. open:upper() .. "<div>" .. close:upper() .. "</p>"), element)
            assert.are.same({ "p", "b", "/b", "/p" }, names("<p>" .. open .. "<i>" .. close .. "<b></b></p>"), element)
            assert.are.same({ "p" }, names("<p>" .. open .. "<div>never closed</p>"), element)
        end
    end)

    it("stops reading at a plaintext, which has no end", function()
        assert.are.same({ "p" }, names("<p><plaintext><div></div></plaintext></p>"))
        assert.are.same({ "p" }, names("<p><PLAINTEXT>"))
        local _, text = htmltags.scan("<p>a<plaintext><b>rest")
        assert.are.equal("<p>a" .. (" "):rep(#"<plaintext><b>rest"), text)
    end)

    it("skips a template whole, counting nested templates", function()
        assert.are.same({ "p", "/p" }, names("<p><template><div><template><b></template></div></template></p>"))
        assert.are.same({ "p", "/p" }, names("<p><template><script>'</template>'</script><i></template></p>"))
        assert.are.same({ "p" }, names("<p><template><div>never closed</p>"))
    end)

    it("skips quoted attribute values, whatever they hold", function()
        local html = [[<a title="x > <div>" data-y='</a>' href=z>t</a>]]
        assert.are.same({ "a", "/a" }, names(html))
        local tags = htmltags.scan(html)
        assert.are.equal((html:find(">t", 1, true)), tags[1].finish)
    end)

    it("starts a quote only after an equals sign", function()
        assert.are.same({ "a", "/a" }, names([[<a it's>x</a>]]))
        assert.are.same({ "a", "/a" }, names([[<a b=it's>x</a>]]))
    end)

    it("reads past a doctype, a processing instruction and a nameless close tag", function()
        assert.are.same({ "p", "/p" }, names('<!DOCTYPE html><?xml a="b"?></><p></ ></p>'))
    end)

    it("treats a < that starts no tag as text", function()
        assert.are.same({ "p", "/p" }, names("<p>1 < 2 <3 <</p>"))
    end)

    it("stops, keeping what it read, when the page ends inside a tag", function()
        assert.are.same({ "p" }, names('<p><div class="a'))
        assert.are.same({ "p" }, names("<p><div"))
        assert.are.same({ "p" }, names("<p><"))
        assert.are.same({}, names(""))
    end)

    describe("the text it returns", function()
        it("is the page itself when nothing was skipped", function()
            local html = "<p>a</p>"
            local _, text = htmltags.scan(html)
            assert.are.equal(html, text)
        end)

        it("blanks what is not markup and keeps every position", function()
            local html = "a<!-- c -->b<script>s</script>c<template>t</template>d<p>e</p>"
            local tags, text = htmltags.scan(html)
            assert.are.equal(#html, #text)
            assert.are.equal("a" .. (" "):rep(10) .. "b" .. (" "):rep(18) .. "c" .. (" "):rep(22) .. "d<p>e</p>", text)
            assert.are.equal("<p>", text:sub(tags[1].start, tags[1].finish))
        end)
    end)

    it("reads a large page in one pass", function()
        local uv = vim.uv or vim.loop
        local parts = {}
        for i = 1, 20000 do parts[i] = '<div class="a"><!-- <b> --><span title="x > y">t</span></div>' end
        local html = table.concat(parts)
        local started = uv.hrtime()
        local tags = htmltags.scan(html)
        assert.are.equal(80000, #tags)
        assert.is_true((uv.hrtime() - started) / 1e9 < 5, "took too long")
    end)
end)
