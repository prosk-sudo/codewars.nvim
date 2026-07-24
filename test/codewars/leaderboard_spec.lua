-- Stub the page fetcher before api.leaderboard is first required.
-- unescape mirrors the real single-pass entity gsub (leaderboard aliases it
-- at require time, so the stub must provide it).
local page_stub = { body = nil, err = nil, calls = {} }
package.loaded["codewars.api.page"] = {
    fetch = function(url, cb)
        table.insert(page_stub.calls, url)
        cb(page_stub.body, page_stub.err)
    end,
    unescape = function(s)
        return (s:gsub("&[#%w]+;", { ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"', ["&#39;"] = "'" }))
    end,
}

-- Mirrors the live structure (verified 2026-07-24): one <tr data-username>
-- per entry, tds = position / user (rank badge + link) / clan / honor.
-- "None" here is a real clan literally named None, not a placeholder.
local SAMPLE_HTML = [[
<table><tr><th class="is-small">Position</th><th>User</th><th>Clan</th><th>Honor</th></tr>
<tr data-username="g964"><td class="rank is-small">#1</td><td class="is-big"><div class="small-hex"><div class="inner-small-hex"><span>1 kyu</span></div></div><a href="/users/g964"><img class="profile-pic" alt="" src="x" />g964</a></td><td>None</td><td class="honor">487,855</td></tr>
<tr data-username="myjinxin2015"><td class="rank is-small">#3</td><td class="is-big"><div><div><span>1 dan</span></div></div><a href="/users/myjinxin2015">myjinxin2015</a></td><td>&#20013;&#22269;</td><td class="honor">398,290</td></tr>
<tr data-username="fc_member"><td class="rank is-small">#7</td><td class="is-big"><div><div><span>4 kyu</span></div></div><a>fc_member</a></td><td>Founders &amp; Coders</td><td class="honor">12,345</td></tr>
<tr data-username="loner"><td class="rank is-small">#500</td><td class="is-big"><div><div><span>8 kyu</span></div></div><a>loner</a></td><td></td><td class="honor">1</td></tr>
</table>
]]

describe("api.leaderboard", function()
    local lb = require("codewars.api.leaderboard")
    local base = require("codewars.api.urls").base

    before_each(function()
        page_stub.body = nil
        page_stub.err = nil
        page_stub.calls = {}
    end)

    describe("parse_html", function()
        it("extracts position, username, rank, clan and honor", function()
            local entries = lb.parse_html(SAMPLE_HTML)
            assert.are.equal(4, #entries)
            assert.are.same(
                { position = 1, username = "g964", rank = "1 kyu", clan = "None", honor = "487,855" },
                entries[1]
            )
            assert.are.equal(500, entries[4].position)
        end)

        it("decodes HTML entities in clans", function()
            local entries = lb.parse_html(SAMPLE_HTML)
            assert.are.equal("Founders & Coders", entries[3].clan)
        end)

        it("maps a blank clan cell to nil (but keeps the literal clan 'None')", function()
            local entries = lb.parse_html(SAMPLE_HTML)
            assert.are.equal("None", entries[1].clan)
            assert.is_nil(entries[4].clan)
        end)

        it("parses dan ranks", function()
            local entries = lb.parse_html(SAMPLE_HTML)
            assert.are.equal("1 dan", entries[2].rank)
        end)

        it("returns empty for a page without leaderboard rows", function()
            assert.are.same({}, lb.parse_html("<html><body>maintenance</body></html>"))
        end)
    end)

    describe("rank_id", function()
        it("converts kyu to negative, dan to positive", function()
            assert.are.equal(-4, lb.rank_id("4 kyu"))
            assert.are.equal(-8, lb.rank_id("8 kyu"))
            assert.are.equal(2, lb.rank_id("2 dan"))
        end)

        it("returns nil for garbage or nil", function()
            assert.is_nil(lb.rank_id(nil))
            assert.is_nil(lb.rank_id("Community"))
            assert.is_nil(lb.rank_id("kyu 4"))
        end)
    end)

    describe("category", function()
        it("resolves all four keys with the right paths", function()
            assert.are.equal("", lb.category("overall").path)
            assert.are.equal("/kata", lb.category("kata").path)
            assert.are.equal("/authored", lb.category("authored").path)
            assert.are.equal("/ranks", lb.category("ranks").path)
        end)

        it("labels the ranks board's numeric column Score", function()
            assert.are.equal("Score", lb.category("ranks").value_label)
            assert.are.equal("Honor", lb.category("overall").value_label)
        end)

        it("returns nil for unknown keys", function()
            assert.is_nil(lb.category("winners"))
        end)
    end)

    describe("fetch", function()
        it("hits the category URL and returns parsed entries", function()
            page_stub.body = SAMPLE_HTML
            local got
            lb.fetch("kata", function(entries, err)
                got = { entries = entries, err = err }
            end)
            assert.are.equal(base .. "/users/leaderboard/kata", page_stub.calls[1])
            assert.is_nil(got.err)
            assert.are.equal(4, #got.entries)
        end)

        it("overall uses the bare leaderboard URL", function()
            page_stub.body = SAMPLE_HTML
            lb.fetch("overall", function() end)
            assert.are.equal(base .. "/users/leaderboard", page_stub.calls[1])
        end)

        it("rejects unknown categories without fetching", function()
            local got_err
            lb.fetch("winners", function(_, err) got_err = err end)
            assert.are.equal(0, #page_stub.calls)
            assert.truthy(got_err.msg:match("Unknown leaderboard category"))
        end)

        it("surfaces transport errors", function()
            page_stub.err = { msg = "curl", curl = true }
            local got_err
            lb.fetch("overall", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("curl error"))
        end)

        it("reports drift when the page yields no rows", function()
            page_stub.body = "<html><body>redesigned</body></html>"
            local got_err
            lb.fetch("overall", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("changed their HTML"))
        end)
    end)
end)

describe("popup.leaderboard format_lines", function()
    local Leaderboard = require("codewars-ui.popup.leaderboard")

    local entries = {
        { position = 1, username = "g964", rank = "1 kyu", clan = "None", honor = "487,855" },
        { position = 25, username = "somebody", rank = "2 dan", clan = "中国 长垣", honor = "98,765" },
        { position = 500, username = "no_rank_user", rank = nil, clan = nil, honor = "1" },
    }

    it("renders header + separator + one line per entry", function()
        local lines = Leaderboard.format_lines(entries, "Honor")
        assert.are.equal(2 + #entries, #lines)
        assert.truthy(lines[1]:match("Pos"))
        assert.truthy(lines[1]:match("Honor"))
    end)

    it("aligns every row to the same display width (incl. CJK clans)", function()
        local lines = Leaderboard.format_lines(entries, "Honor")
        local w = vim.fn.strdisplaywidth(lines[1])
        for i = 3, #lines do
            assert.are.equal(w, vim.fn.strdisplaywidth(lines[i]))
        end
    end)

    it("shows position, name and honor", function()
        local lines = Leaderboard.format_lines(entries, "Honor")
        assert.truthy(lines[3]:match("#1%s"))
        assert.truthy(lines[3]:match("g964"))
        assert.truthy(lines[3]:match("487,855"))
    end)

    it("uses the Score header for the ranks board", function()
        local lines = Leaderboard.format_lines(entries, "Score")
        assert.truthy(lines[1]:match("Score"))
    end)

    it("colors ranks via the theme and skips missing ranks", function()
        local _, highlights = Leaderboard.format_lines(entries, "Honor")
        local rank_hls = vim.tbl_filter(function(h)
            return h[4]:match("^codewars_rank_")
        end, highlights)
        -- rows 1+2 have ranks, row 3 does not
        assert.are.equal(2, #rank_hls)
    end)

    it("expands User and Clan to fill a target width (Pos/Honor stay compact)", function()
        local lines = Leaderboard.format_lines(entries, "Honor", 100)
        assert.are.equal(100, vim.fn.strdisplaywidth(lines[1]))
        for i = 3, #lines do
            assert.are.equal(100, vim.fn.strdisplaywidth(lines[i]))
        end
        -- honor still hugs the right edge
        assert.truthy(lines[3]:match("487,855$"))
    end)

    it("squeezes User/Clan on narrow targets instead of overflowing the popup", function()
        local long = {
            { position = 1, username = string.rep("u", 30), rank = "1 kyu", clan = string.rep("c", 30), honor = "487,855" },
        }
        for _, target in ipairs({ 46, 62, 70 }) do
            local lines = Leaderboard.format_lines(long, "Honor", target)
            for i = 3, #lines do
                assert.are.equal(target, vim.fn.strdisplaywidth(lines[i]))
            end
            assert.truthy(lines[3]:match("487,855"))
        end
    end)

    it("truncates to the expanded clan share when a clan overflows it", function()
        local long = {
            { position = 1, username = "u", rank = "8 kyu", clan = string.rep("c", 60), honor = "1" },
        }
        local lines = Leaderboard.format_lines(long, "Honor", 80)
        assert.are.equal(80, vim.fn.strdisplaywidth(lines[3]))
        assert.truthy(lines[3]:find("…", 1, true))
    end)

    it("truncates over-long clans with an ellipsis", function()
        local long = {
            { position = 1, username = "u", rank = "8 kyu", clan = string.rep("c", 40), honor = "1" },
        }
        local lines = Leaderboard.format_lines(long, "Honor")
        assert.truthy(lines[3]:find("…", 1, true))
    end)
end)

describe("cmd.leaderboard", function()
    package.loaded["codewars.config"] = {
        user = { keys = { toggle = { "q" } }, logging = false, debug = false, username = "prosk" },
        lang = "python",
        langs = {
            { slug = "python", lang = "Python", ft = "py", comment = "#" },
        },
    }

    local logged = {}
    package.loaded["codewars.logger"] = {
        info = function(m) table.insert(logged, { "info", m }) end,
        warn = function(m) table.insert(logged, { "warn", m }) end,
        error = function(m) table.insert(logged, { "error", m }) end,
        err = function(e) table.insert(logged, { "err", e }) end,
        debug = function() end,
    }

    local fetch_calls = {}
    local fetch_response = { entries = { { position = 1, username = "g964", honor = "1" } }, err = nil }
    package.loaded["codewars.api.leaderboard"] = {
        fetch = function(key, cb)
            table.insert(fetch_calls, key)
            cb(fetch_response.entries, fetch_response.err)
        end,
    }

    local shown = {}
    package.loaded["codewars-ui.popup.leaderboard"] = {
        new = function(_, entries, key)
            return {
                show = function() table.insert(shown, { entries = entries, key = key }) end,
            }
        end,
    }

    local picker_choice = "ranks"
    package.loaded["codewars.picker"] = {
        leaderboard_category = function(cb) cb(picker_choice) end,
    }

    package.loaded["codewars.command"] = nil
    local cmd = require("codewars.command")

    before_each(function()
        logged = {}
        fetch_calls = {}
        shown = {}
        fetch_response = { entries = { { position = 1, username = "g964", honor = "1" } }, err = nil }
    end)

    it("direct category: fetches and shows the popup", function()
        cmd.leaderboard({ _positional = { "kata" } })
        assert.are.same({ "kata" }, fetch_calls)
        assert.are.equal("kata", shown[1].key)
    end)

    it("rejects unknown categories without fetching", function()
        cmd.leaderboard({ _positional = { "winners" } })
        assert.are.equal(0, #fetch_calls)
        assert.are.equal(0, #shown)
        assert.are.equal("error", logged[1][1])
        assert.truthy(logged[1][2]:match("Unknown leaderboard category"))
    end)

    it("no args: routes through the category picker", function()
        cmd.leaderboard({})
        assert.are.same({ "ranks" }, fetch_calls)
        assert.are.equal("ranks", shown[1].key)
    end)

    it("fetch errors are reported, nothing shows", function()
        fetch_response = { entries = nil, err = { msg = "boom" } }
        cmd.leaderboard({ _positional = { "overall" } })
        assert.are.equal(0, #shown)
        local last = logged[#logged]
        assert.are.equal("err", last[1])
        assert.are.equal("boom", last[2].msg)
    end)

    it(":CW exec routes 'leaderboard authored'", function()
        cmd.exec({ name = "CW", args = "leaderboard authored" })
        assert.are.same({ "authored" }, fetch_calls)
    end)
end)
