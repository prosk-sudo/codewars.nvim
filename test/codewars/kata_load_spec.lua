local kata_page = require("codewars.api.kata_page")

local KATA_ID = "6a63e7e085269ff93dc6332e"
local LANG_ID = "6a63e7e085269ff93dc6332f"

--- A miniature of the real edit page (contract captured 2026-07-25). It keeps
--- the three things that actually break naive parsers:
---   * the embedded blob is a JS string literal holding JSON, so every quote
---     arrives as `\"` — and one value below contains `\")`, the sequence that
---     terminates a lazy `"(.-)"%)` match early;
---   * language fields are percent-encoded;
---   * form controls list their attributes in DIFFERENT orders (`value` before
---     `name` on one input, `type` before `value` on the next).
local function edit_page(opts)
    opts = opts or {}
    local blob = table.concat({
        [[{\"routes\":{},\"controllerName\":\"code_challenges\",\"language\":\"python\",]],
        [[\"languages\":{\"python\":{\"id\":\"]] .. LANG_ID .. [[\",\"name\":\"python\",]],
        -- def hi():\n    return "a)b"  — the answer also exercises \") handling
        [[\"answer\":\"def%20hi%28%29%3A%0A%20%20%20%20return%20%22a%29b%22\",]],
        [[\"setup\":\"%23%20start%20here\",\"fixture\":\"test%0Amore\",]],
        [[\"example_fixture\":\"%23%20sample\",\"package\":\"\"}},]],
        [[\"published\":]] .. tostring(opts.published == true) .. [[,]],
        [[\"id\":\"]] .. KATA_ID .. [[\",\"fixturesLocked\":false,]],
        [[\"testFrameworks\":{\"python\":\"cw-2\"},\"quirk\":\"x\\\")y\"}]],
    })

    local rank = opts.rank or ""
    local checked = opts.coauthors == false and "" or [[checked="checked" ]]
    return table.concat({
        [[<html><body><script>App.setup({ env: "production", currentUser, data: JSON.parse("]],
        blob,
        [[") });</script>]],
        [[<form class="simple_form edit_code_challenge">]],
        [[<input class="string optional" type="text" value="]],
        opts.name or "prosk&#39;s Kumite #3",
        [[" name="code_challenge[name]" id="code_challenge_name" />]],
        [[<input autocomplete="off" type="hidden" value="algorithms" name="code_challenge[category]" id="code_challenge_category" />]],
        [[<select name="code_challenge[estimated_rank]" id="code_challenge_estimated_rank">]],
        rank == "" and [[<option selected="selected" value=""></option>]] or [[<option value=""></option>]],
        [[<option ]] .. (rank == "-6" and [[selected="selected" ]] or "") .. [[value="-6">6 kyu (yellow)</option>]],
        [[</select>]],
        [[<input class="string optional" type="text" value="]],
        opts.tags or "",
        [[" name="code_challenge[tags_text]" id="code_challenge_tags_text" />]],
        [[<input name="code_challenge[coauthors_wanted]" type="hidden" value="false" />]],
        [[<input ]] .. checked .. [[class="form-checkbox" id="code_challenge_coauthors_wanted" name="code_challenge[coauthors_wanted]" type="checkbox" value="true" />]],
        [[<textarea class="text optional" name="code_challenge[description]" id="code_challenge_description">]],
        "\n" .. (opts.description or "Solve it &amp; have fun &lt;3"),
        [[</textarea></form></body></html>]],
    })
end

describe("kata_page.percent_decode", function()
    it("decodes %XX and leaves + alone (encodeURIComponent never emits +)", function()
        assert.are.equal('return "a)b"', kata_page.percent_decode("return%20%22a%29b%22"))
        assert.are.equal("a+b", kata_page.percent_decode("a+b"))
        assert.are.equal("", kata_page.percent_decode(nil))
    end)
end)

describe("kata_page.parse_data_blob", function()
    it("survives an escaped quote-paren inside the JS string literal", function()
        local data = kata_page.parse_data_blob(edit_page())
        assert.is_table(data)
        assert.are.equal(KATA_ID, data.id)
        -- Proof the scanner ran to the true end of the literal, not the first ")
        assert.are.equal('x")y', data.quirk)
    end)

    it("returns nil when the page carries no blob", function()
        assert.is_nil(kata_page.parse_data_blob("<html>nothing here</html>"))
        assert.is_nil(kata_page.parse_data_blob(nil))
    end)
end)

describe("kata_page.parse_edit_page", function()
    it("decodes the language fields and reads every code_challenge control", function()
        local m = kata_page.parse_edit_page(edit_page())

        assert.are.equal(KATA_ID, m.id)
        assert.are.equal("python", m.language)
        assert.is_false(m.published)
        assert.are.equal("cw-2", m.test_frameworks.python)

        local py = m.languages.python
        assert.are.equal(LANG_ID, py.id)
        assert.are.equal('def hi():\n    return "a)b"', py.answer)
        assert.are.equal("# start here", py.setup)
        assert.are.equal("test\nmore", py.fixture)
        assert.are.equal("# sample", py.example_fixture)
        assert.are.equal("", py["package"])

        local cc = m.code_challenge
        assert.are.equal("prosk's Kumite #3", cc.name) -- &#39; unescaped
        assert.are.equal("algorithms", cc.category)
        assert.are.equal("", cc.estimated_rank) -- blank option is the selected one
        assert.are.equal("", cc.tags_text)
        assert.is_true(cc.coauthors_wanted)
        -- leading newline after <textarea> is HTML padding, not content
        assert.are.equal("Solve it & have fun <3", cc.description)
    end)

    it("reads a chosen rank, cleared checkbox, tags and published state", function()
        local m = kata_page.parse_edit_page(edit_page({
            published = true,
            rank = "-6",
            coauthors = false,
            tags = "Algorithms, Strings",
        }))
        assert.is_true(m.published)
        assert.are.equal("-6", m.code_challenge.estimated_rank)
        assert.is_false(m.code_challenge.coauthors_wanted)
        assert.are.equal("Algorithms, Strings", m.code_challenge.tags_text)
    end)

    it("returns nil for a page that is not an editor", function()
        -- A deleted kata redirects to the marketing page, which still calls
        -- App.setup but carries no kata data.
        local decoy = [[<html><script>App.setup({ data: JSON.parse("{\"routes\":{}}") });</script></html>]]
        assert.is_nil(kata_page.parse_edit_page(decoy))
        assert.is_nil(kata_page.parse_edit_page("<html></html>"))
    end)
end)

describe("kata_page.parse_ref", function()
    it("accepts a bare id and every kata URL form", function()
        assert.are.equal(KATA_ID, kata_page.parse_ref(KATA_ID))
        assert.are.equal(KATA_ID, kata_page.parse_ref("https://www.codewars.com/kata/" .. KATA_ID))
        assert.are.equal(KATA_ID, kata_page.parse_ref("https://www.codewars.com/kata/" .. KATA_ID .. "/edit/python"))
        assert.are.equal(KATA_ID, kata_page.parse_ref("  /kata/" .. KATA_ID .. "/train  "))
    end)

    it("rejects junk", function()
        assert.is_nil(kata_page.parse_ref("not-an-id"))
        assert.is_nil(kata_page.parse_ref(nil))
        assert.is_nil(kata_page.parse_ref("/kumite/" .. KATA_ID))
    end)
end)
