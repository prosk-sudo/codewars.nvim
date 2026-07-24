-- Stub the page fetcher before api.kumite is first required (it aliases
-- page.unescape at require time, so the stub must provide it).
local page_stub = { body = nil, err = nil, calls = {} }
package.loaded["codewars.api.page"] = package.loaded["codewars.api.page"] or {}
local page_mod = package.loaded["codewars.api.page"]
page_mod.fetch = function(url, cb)
    table.insert(page_stub.calls, url)
    cb(page_stub.body, page_stub.err)
end
page_mod.unescape = page_mod.unescape or function(s)
    return (s:gsub("&[#%w]+;", { ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"', ["&#39;"] = "'" }))
end

-- Mirrors the live list markup (verified 2026-07-24): item roots are
-- div.code-snippet-list-item with trailing utility classes; each item has
-- one Fork link naming the snippet id. First item = fork ("A vs. B",
-- ?sel= title link), second = root kumite (single author, plain link).
local ID_FORK = "6a40a970203695341bd8e654"
local ID_PARENT = "5ba1f77a9935d8b03f000095"
local ID_ROOT = "6a4d565c4d94d89f2e34fca8"
local SAMPLE_LIST = [[
<section class="items-list"><div class="space-y-4"><div class="shadow-md"><div class="code-snippet-list-item bg-ui-section p-2"><div class="x"><i class="icon-moon-user "></i><a href="/users/aaa">AdisaOyo</a><span class="mx-1">vs.</span><a href="/users/bbb">umlittlethings</a></span><span><i class="icon-moon-publish "></i><time-ago class="ml-1" datetime="2026-06-28T04:56:24.373+0000" lang="en"></time-ago></span><h3 class="m-0"><a class="is-alt" href="/kumite/]] .. ID_PARENT .. [[?sel=]] .. ID_FORK .. [[">compare &amp; win</a></h3><pre lang="python"><code>compare = lambda a, b: a if a &gt; b else b</code></pre><ul><li><a href="/kumite/new?parent=]] .. ID_FORK .. [["><i class="icon-moon-forked "></i>Fork</a></li></ul></div></div>
<div class="shadow-md"><div class="code-snippet-list-item bg-ui-section p-2"><div class="x"><i class="icon-moon-user "></i><a href="/users/ccc">solo_author</a></span><span><time-ago class="ml-1" datetime="2018-09-19T07:32:03.682+0000"></time-ago></span><h3 class="m-0"><a class="is-alt" href="/kumite/]] .. ID_ROOT .. [[">Big number</a></h3><pre lang="java"><code>public class BiggerNum {}</code></pre><ul><li><a href="/kumite/new?parent=]] .. ID_ROOT .. [[">Fork</a></li></ul></div></div></div></section>
<nav class="pagination"><span class="page current">3</span> <span class="page"><a href="/kumite?page=4">4</a></span> <span class="page gap">&hellip;</span> <span class="page"><a href="/kumite?page=1308">1308</a></span></nav>
]]

describe("kumite.state", function()
    local st = require("codewars.kumite.state")

    it("covers the full transition matrix", function()
        for state_name, row in pairs(st.transitions) do
            for action, cell in pairs(row) do
                local next_state, err = st.step(state_name, action)
                if type(cell) == "table" then
                    assert.is_nil(next_state)
                    assert.are.equal(cell.err, err)
                else
                    assert.are.equal(cell, next_state)
                    assert.is_nil(err)
                end
            end
        end
    end)

    it("fork is a local transition from both read-only states", function()
        assert.are.equal("local_fork", (st.step("published_view", "fork")))
        assert.are.equal("local_fork", (st.step("published", "fork")))
    end)

    it("read-only edit names the fork escape hatch", function()
        local _, err = st.step("published_view", "edit")
        assert.truthy(err:match(":CW kumite fork"))
    end)

    it("in-flight states reject repeated writes with state-aware messages", function()
        local _, err = st.step("saving", "publish")
        assert.truthy(err:match("Saving in progress"))
        local _, err2 = st.step("publishing", "save")
        assert.truthy(err2:match("Publishing in progress"))
    end)

    it("failures revert via the sentinel; successes land correctly", function()
        assert.are.equal(st.REVERT, (st.step("saving", "save_failed")))
        assert.are.equal("server_draft", (st.step("saving", "save_done")))
        assert.are.equal(st.REVERT, (st.step("publishing", "publish_failed")))
        assert.are.equal("published", (st.step("publishing", "publish_done")))
    end)

    it("classifies editable and locked states", function()
        assert.is_true(st.is_editable("local_fork"))
        assert.is_false(st.is_editable("published_view"))
        assert.is_true(st.is_locked("publishing"))
        assert.is_false(st.is_locked("server_draft"))
    end)

    it("unknown action yields a named rejection, unknown state asserts", function()
        local _, err = st.step("published_view", "teleport")
        assert.truthy(err:match("not available"))
        assert.has_error(function() st.step("nirvana", "run") end)
    end)
end)

describe("api.kumite", function()
    local kumite = require("codewars.api.kumite")

    before_each(function()
        page_stub.body = nil
        page_stub.err = nil
        page_stub.calls = {}
    end)

    describe("parse_ref", function()
        it("accepts a raw 24-hex id", function()
            assert.are.equal(ID_FORK, kumite.parse_ref(ID_FORK))
        end)

        it("prefers sel= from canonical fork links", function()
            local url = "https://www.codewars.com/kumite/" .. ID_PARENT .. "?sel=" .. ID_FORK
            assert.are.equal(ID_FORK, kumite.parse_ref(url))
        end)

        it("takes the path id from plain kumite links", function()
            assert.are.equal(ID_ROOT, kumite.parse_ref("https://www.codewars.com/kumite/" .. ID_ROOT))
        end)

        it("rejects garbage", function()
            assert.is_nil(kumite.parse_ref("not-a-kumite"))
            assert.is_nil(kumite.parse_ref(nil))
            assert.is_nil(kumite.parse_ref("/kata/multiply"))
        end)
    end)

    describe("parse_list_html", function()
        it("extracts both fork and root items with all fields", function()
            local result = kumite.parse_list_html(SAMPLE_LIST)
            assert.are.equal(2, #result.entries)

            local fork = result.entries[1]
            assert.are.equal(ID_FORK, fork.id)
            assert.are.equal(ID_PARENT, fork.parent_id)
            assert.are.equal("compare & win", fork.title)
            assert.are.equal("AdisaOyo", fork.author)
            assert.are.equal("umlittlethings", fork.forked_from_author)
            assert.are.equal("python", fork.language)
            assert.are.equal("2026-06-28T04:56:24.373+0000", fork.published_at)
            assert.truthy(fork.code:match("a if a > b else b"))

            local root = result.entries[2]
            assert.are.equal(ID_ROOT, root.id)
            assert.is_nil(root.parent_id)
            assert.are.equal("solo_author", root.author)
            assert.is_nil(root.forked_from_author)
        end)

        it("reads current and last page from the pagination block", function()
            local result = kumite.parse_list_html(SAMPLE_LIST)
            assert.are.equal(3, result.current_page)
            assert.are.equal(1308, result.last_page)
        end)

        it("defaults to page 1/1 without pagination and no items on foreign html", function()
            local result = kumite.parse_list_html("<html><body>maintenance</body></html>")
            assert.are.equal(0, #result.entries)
            assert.are.equal(1, result.current_page)
            assert.are.equal(1, result.last_page)
        end)
    end)

    describe("fetch_list", function()
        it("builds the language+page URL and returns parsed entries", function()
            page_stub.body = SAMPLE_LIST
            local got
            kumite.fetch_list("python", 3, function(result, err)
                got = { result = result, err = err }
            end)
            assert.truthy(page_stub.calls[1]:match("/kumite%?language=python&page=3$"))
            assert.is_nil(got.err)
            assert.are.equal(2, #got.result.entries)
        end)

        it("omits query parts for all-languages page 1", function()
            page_stub.body = SAMPLE_LIST
            kumite.fetch_list(nil, 1, function() end)
            assert.truthy(page_stub.calls[1]:match("/kumite$"))
        end)

        it("reports drift when the kumite markup is gone entirely", function()
            page_stub.body = "<html><body>redesigned</body></html>"
            local got_err
            kumite.fetch_list(nil, 1, function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("changed their HTML"))
        end)

        it("treats a marker-bearing page with zero items as empty, not drift", function()
            page_stub.body = '<div class="code-snippet-x"></div><section class="items-list"></section>'
            local got
            kumite.fetch_list(nil, 1, function(result, err) got = { result = result, err = err } end)
            assert.is_nil(got.err)
            assert.are.equal(0, #got.result.entries)
        end)

        it("surfaces transport errors", function()
            page_stub.err = { msg = "curl", curl = true }
            local got_err
            kumite.fetch_list(nil, 1, function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("curl error"))
        end)
    end)

    describe("fetch_snippet", function()
        local get_calls
        before_each(function()
            get_calls = {}
        end)

        local function stub_get(response, err)
            package.loaded["codewars.api.utils"] = {
                get = function(endpoint, opts)
                    table.insert(get_calls, endpoint)
                    opts.callback(response, err)
                end,
            }
        end

        it("normalizes the JSON model with defaults for absent fields", function()
            stub_get({ id = ID_ROOT, title = "Big number", language = "java",
                code = "x", testFramework = "junit", state = "published",
                user = { username = "tarkhnas" } })
            local got
            kumite.fetch_snippet(ID_ROOT, function(snippet, err) got = { snippet = snippet, err = err } end)
            assert.are.equal("/api/v1/code-snippets/" .. ID_ROOT, get_calls[1])
            assert.is_nil(got.err)
            assert.are.equal("Big number", got.snippet.title)
            assert.are.equal("junit", got.snippet.test_framework)
            assert.are.equal("tarkhnas", got.snippet.author)
            assert.are.equal("", got.snippet.fixture)
            assert.is_nil(got.snippet.parent_id)
        end)

        it("rejects an unexpected response shape as drift", function()
            stub_get("<html>login</html>")
            local got_err
            kumite.fetch_snippet(ID_ROOT, function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("changed their API"))
        end)

        it("passes through auth errors untouched", function()
            stub_get(nil, { msg = "Session expired", auth = true })
            local got_err
            kumite.fetch_snippet(ID_ROOT, function(_, err) got_err = err end)
            assert.is_true(got_err.auth)
        end)
    end)
end)

describe("cmd.kumite", function()
    package.loaded["codewars.config"] = {
        user = { keys = { toggle = { "q" } }, logging = false, debug = false, username = "prosk" },
        lang = "python",
        langs = { { slug = "python", lang = "Python", ft = "py", comment = "#" } },
    }

    local logged = {}
    package.loaded["codewars.logger"] = {
        info = function(m) table.insert(logged, { "info", m }) end,
        warn = function(m) table.insert(logged, { "warn", m }) end,
        error = function(m) table.insert(logged, { "error", m }) end,
        err = function(e) table.insert(logged, { "err", e }) end,
        debug = function() end,
    }

    local browse_calls = 0
    package.loaded["codewars.picker"] = {
        kumite_browse = function() browse_calls = browse_calls + 1 end,
    }

    local fetch_calls = {}
    local fetch_response = { snippet = { id = ID_ROOT, title = "Big number", language = "java", code = "x" }, err = nil }
    package.loaded["codewars.api.kumite"] = {
        parse_ref = require("codewars.api.kumite").parse_ref,
        fetch_snippet = function(id, cb)
            table.insert(fetch_calls, id)
            cb(fetch_response.snippet, fetch_response.err)
        end,
    }

    local mounted = {}
    package.loaded["codewars-ui.kumite"] = {
        new = function(_, snippet)
            return { mount = function() table.insert(mounted, snippet.id) end }
        end,
    }

    package.loaded["codewars.command"] = nil
    local cmd = require("codewars.command")

    before_each(function()
        logged = {}
        browse_calls = 0
        fetch_calls = {}
        mounted = {}
        fetch_response = { snippet = { id = ID_ROOT, title = "Big number", language = "java", code = "x" }, err = nil }
    end)

    it(":CW kumite routes to the browser", function()
        cmd.exec({ name = "CW", args = "kumite" })
        assert.are.equal(1, browse_calls)
    end)

    it(":CW kumite open <url> parses the ref, fetches and mounts", function()
        cmd.exec({ name = "CW", args = "kumite open https://www.codewars.com/kumite/" .. ID_PARENT .. "?sel=" .. ID_FORK })
        assert.are.same({ ID_FORK }, fetch_calls)
        vim.wait(50, function() return #mounted > 0 end)
        assert.are.same({ ID_ROOT }, mounted)
    end)

    it(":CW kumite open without a valid ref logs usage", function()
        cmd.kumite_open({ _positional = { "garbage" } })
        assert.are.equal(0, #fetch_calls)
        assert.are.equal("error", logged[1][1])
        assert.truthy(logged[1][2]:match("Usage"))
    end)

    it("fetch errors are reported, nothing mounts", function()
        fetch_response = { snippet = nil, err = { msg = "boom" } }
        cmd.kumite_open({ _positional = { ID_ROOT } })
        assert.are.equal(0, #mounted)
        local last = logged[#logged]
        assert.are.equal("err", last[1])
    end)
end)
