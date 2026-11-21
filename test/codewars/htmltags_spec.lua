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
        assert.are.same({ name = "div", close = false, start = 3, finish = 19, class = "x y", empty = false }, tags[1])
        assert.are.equal("</div>", html:sub(tags[2].start, tags[2].finish))
        assert.is_true(tags[2].close)
    end)

    it("lower-cases names and reads the class attribute in any case", function()
        local tags = htmltags.scan("<DIV CLASS='A b'></DIV>")
        assert.are.equal("div", tags[1].name)
        assert.are.equal("A b", tags[1].class)
        assert.are.equal("div", tags[2].name)
    end)

    it("takes the first class attribute, and only a real one", function()
        assert.are.equal("a", htmltags.scan('<p class="a" class="b">')[1].class)
        assert.is_nil(htmltags.scan('<p data-class="a" title="class=\'b\'">')[1].class)
        assert.is_nil(htmltags.scan("<p>")[1].class)
        assert.are.equal("a", htmltags.scan("<p class=a>")[1].class)
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
