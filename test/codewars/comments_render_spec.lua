-- The comment thread used to be raw markdown in a scratch buffer: a pane
-- full of `**` and `_`, and code fences shown verbatim. This renderer
-- produces plain text plus highlight spans so every user sees the same
-- thing without a markdown grammar or conceal setup.
describe("solution comments renderer", function()
    local R = require("codewars-ui.popup.comments")

    local function groups_at(spans, row, group)
        local out = {}
        for _, s in ipairs(spans) do
            if s[1] == row and s[4] == group then out[#out + 1] = { s[2], s[3] } end
        end
        return out
    end

    describe("inline", function()
        it("strips bold/italic markers and marks the runs", function()
            local text, spans = R.inline("a **bold** and _it_ and __b2__ and *i2*", 0, 0)
            assert.are.equal("a bold and it and b2 and i2", text)
            assert.are.same({ { 2, 6 }, { 18, 20 } }, groups_at(spans, 0, "codewars_comment_bold"))
            assert.are.same({ { 11, 13 }, { 25, 27 } }, groups_at(spans, 0, "codewars_comment_italic"))
        end)

        it("renders code spans without the backticks", function()
            local text, spans = R.inline("use `s[1:-1]` here", 0, 4)
            assert.are.equal("use s[1:-1] here", text)
            assert.are.same({ { 8, 15 } }, groups_at(spans, 0, "codewars_comment_code"))
        end)

        it("shows a link's text, not its url", function()
            local text, spans = R.inline("see [the docs](https://x.y/z) now", 3, 0)
            assert.are.equal("see the docs now", text)
            assert.are.same({ { 4, 12 } }, groups_at(spans, 3, "codewars_comment_link"))
        end)

        it("leaves snake_case, arithmetic and unmatched markers alone", function()
            local text = R.inline("my_var * 2 * x and lone_ and **open", 0, 0)
            assert.are.equal("my_var * 2 * x and lone_ and **open", text)
        end)

        it("does not mistake a marker glued to a word for emphasis", function()
            local text = R.inline("2*3*4 equals 24", 0, 0)
            assert.are.equal("2*3*4 equals 24", text)
        end)
    end)

    describe("render", function()
        local function c(o)
            return vim.tbl_extend("force", {
                id = "c", author = "alice", rank = "1 kyu", body = "hi", created = "2026-06-05",
                score = 2, depth = 0, masked = false,
            }, o or {})
        end

        it("header carries author, rank (coloured by rank), date, score and spoiler", function()
            local lines, spans = R.render({ c({ masked = true, score = -2, rank = "7 kyu" }) })
            assert.are.equal("● alice  7 kyu  ·  2026-06-05  ·  ▲ -2   spoiler", lines[1])
            assert.are.same({ { 4, 9 } }, groups_at(spans, 0, "codewars_comment_author"))
            assert.are.equal(1, #groups_at(spans, 0, "codewars_rank_white")) -- 7 kyu is white
            assert.are.equal(1, #groups_at(spans, 0, "codewars_error")) -- negative score
            assert.are.equal(1, #groups_at(spans, 0, "codewars_warning")) -- spoiler
            local _, sp2 = R.render({ c({ rank = "2 dan", score = 5 }) })
            assert.are.equal(1, #groups_at(sp2, 0, "codewars_rank_purple"))
            assert.are.equal(1, #groups_at(sp2, 0, "codewars_ok"))
        end)

        it("indents the body and replies, and blank-lines between comments", function()
            local lines = R.render({
                c({ body = "top" }),
                c({ author = "bob", depth = 1, body = "reply" }),
                c({ author = "cy", body = "next" }),
            })
            assert.are.same({
                "● alice  1 kyu  ·  2026-06-05  ·  ▲ 2", "  top", "",
                "  ↳ bob  1 kyu  ·  2026-06-05  ·  ▲ 2", "    reply", "",
                "● cy  1 kyu  ·  2026-06-05  ·  ▲ 2", "  next",
            }, lines)
        end)

        it("keeps fenced code verbatim, drops the fence lines, highlights the block", function()
            local body = "look:\n```python\ndef f(x):\n    return x[1:-1]\n```\ndone"
            local lines, spans = R.render({ c({ body = body }) })
            assert.are.same({ "  look:", "  def f(x):", "      return x[1:-1]", "  done" }, { lines[2], lines[3], lines[4], lines[5] })
            assert.are.equal(1, #groups_at(spans, 2, "codewars_comment_code"))
            assert.are.equal(1, #groups_at(spans, 3, "codewars_comment_code"))
            assert.are.equal(0, #groups_at(spans, 4, "codewars_comment_code"))
        end)

        it("decodes entities, turns <br> into a line break and drops other tags", function()
            local lines = R.render({ c({ body = "a &lt; b<br>next <sub><sup>small</sup></sub> &amp; done" }) })
            assert.are.same({ "  a < b", "  next small & done" }, { lines[2], lines[3] })
        end)

        it("trims trailing blank lines in a body", function()
            local lines = R.render({ c({ body = "text\n\n  \n" }), c({ author = "z" }) })
            assert.are.same({ "  text", "" }, { lines[2], lines[3] })
        end)

        it("says so when there are no comments", function()
            local lines = R.render({})
            assert.are.same({ "No comments yet." }, lines)
        end)

        it("paints into a buffer without error", function()
            local buf = vim.api.nvim_create_buf(false, true)
            R.paint(buf, R.render({ c({ body = "**b** `c`" }) }))
            assert.are.equal("  b c", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
            local ns = vim.api.nvim_create_namespace("codewars_solution_comments")
            assert.is_true(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) >= 3)
        end)
    end)
end)
