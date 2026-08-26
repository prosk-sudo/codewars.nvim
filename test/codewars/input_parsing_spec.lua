local cmd = require("codewars.command")
local page = require("codewars.api.page")
local user = require("codewars.api.user")
local comments = require("codewars-ui.popup.comments")
local markdown = require("codewars-ui.markdown")

local function capture_errors()
    local log = require("codewars.logger")
    local real, seen = log.error, {}
    log.error = function(msg)
        seen[#seen + 1] = msg
    end
    return seen, function()
        log.error = real
    end
end

describe("cmd.tokenize", function()
    it("splits on whitespace and keeps quoted titles whole", function()
        assert.same({ "train", "Unique In Order", "python" }, cmd.tokenize('train "Unique In Order" python'))
        assert.same({ "train", "it's", "x" }, cmd.tokenize("train \"it's\" x"))
        assert.same({ "list", "difficulty=8,7" }, cmd.tokenize("  list   difficulty=8,7 "))
        assert.same({}, cmd.tokenize(""))
        -- a quote inside a word, or one that never closes, is ordinary text
        assert.same({ "train", "it's-a-title", "python" }, cmd.tokenize("train it's-a-title python"))
        assert.same({ "train", "'oops", "python" }, cmd.tokenize("train 'oops python"))
    end)
end)

describe("cmd.train arguments", function()
    local real_kata, real_guard, opened

    before_each(function()
        opened = {}
        real_kata = package.loaded["codewars-ui.kata"]
        package.loaded["codewars-ui.kata"] = {
            new = function(_, slug, lang)
                opened[#opened + 1] = { slug = slug, lang = lang }
                return { mount = function() end }
            end,
        }
        real_guard = require("codewars.utils").auth_guard
        require("codewars.utils").auth_guard = function() end
    end)

    after_each(function()
        package.loaded["codewars-ui.kata"] = real_kata
        require("codewars.utils").auth_guard = real_guard
    end)

    it("joins a bare multi-word title and takes a trailing language", function()
        cmd.train({ _positional = { "Unique", "In", "Order", "python" } })
        assert.same({ { slug = "unique-in-order", lang = "python" } }, opened)
        cmd.train({ _positional = { "Unique", "In", "Order" } })
        assert.equals("unique-in-order", opened[2].slug)
    end)

    it("rejects an unknown language as the second of two words instead of asserting later", function()
        local errors, restore = capture_errors()
        cmd.train({ _positional = { "unique-in-order", "rubyx" } })
        cmd.train({ _positional = { "multiples", "rubyx" } })
        restore()
        assert.same({}, opened)
        assert.truthy(errors[1]:find("Unknown language: rubyx", 1, true))
        assert.truthy(errors[2]:find("Unknown language: rubyx", 1, true))
    end)

    it("completion tokenizes the way exec does", function()
        local positional = cmd.parse('train "Unique In Order" py')
        assert.same({ "train", "Unique In Order", "py" }, positional)
        assert.same({ "train", "" }, cmd.parse("train "))
    end)
end)

describe(":CW list completion", function()
    it("keeps the key= prefix and the values already typed", function()
        assert.same({ "difficulty=8", "difficulty=7", "difficulty=6", "difficulty=5",
            "difficulty=4", "difficulty=3", "difficulty=2", "difficulty=1" }, cmd.complete(nil, "CW list difficulty="))
        assert.equals("difficulty=8,7", cmd.complete(nil, "CW list difficulty=8,")[1])
        assert.same({}, cmd.complete(nil, "CW list difficulty=8,7"))
        assert.same({ "order=hardest" }, cmd.complete(nil, "CW list order=h"))
    end)
end)

describe(":CW list order", function()
    local real_guard, real_picker, got

    before_each(function()
        got = nil
        real_guard = require("codewars.utils").auth_guard
        require("codewars.utils").auth_guard = function() end
        real_picker = package.loaded["codewars.picker"]
        package.loaded["codewars.picker"] = { problems = function(opts) got = opts end }
    end)

    after_each(function()
        require("codewars.utils").auth_guard = real_guard
        package.loaded["codewars.picker"] = real_picker
    end)

    it("maps order= to a picker sort mode and difficulty= to ranks", function()
        cmd.list({ order = { "hardest" }, difficulty = { "8", "7" } })
        assert.equals("hardest", got.sort_key)
        assert.same({ -8, -7 }, got.rank)
        cmd.list({ order = { "shuffle" } })
        assert.equals("shuffle", got.sort_key)
    end)

    it("rejects an order the cached list cannot honour", function()
        local errors, restore = capture_errors()
        cmd.list({ order = { "newest" } })
        restore()
        assert.is_nil(got)
        assert.truthy(errors[1]:find("Invalid order: newest", 1, true))
    end)
end)

describe(":CW list difficulty", function()
    it("reports a non-numeric difficulty instead of raising", function()
        -- list checks the cookie first; CI has none, so stand in for it.
        local utils = require("codewars.utils")
        local real_guard = utils.auth_guard
        utils.auth_guard = function() end
        local errors, restore = capture_errors()
        local ok = pcall(cmd.list, { difficulty = { "abc" } })
        restore()
        utils.auth_guard = real_guard
        assert.is_true(ok)
        assert.truthy(errors[1]:find("Invalid difficulty: abc", 1, true))
    end)
end)

describe("page.unescape", function()
    it("decodes numeric and hex entities alongside named ones", function()
        assert.equals("Tom’s <clan> & co ©", page.unescape("Tom&#8217;s &lt;clan&gt; &amp; co &#xA9;"))
        assert.equals("&bogus; &#; &#55296;", page.unescape("&bogus; &#; &#55296;"))
    end)
end)

describe("user.parse_literal", function()
    it("reads the whole JSON.parse literal past escaped quotes", function()
        local body = [[x; currentUser = JSON.parse("{\"a\":\"x\")y\",\"n\":1}"); y]]
        assert.equals([[{\"a\":\"x\")y\",\"n\":1}]], user.parse_literal(body))
        assert.is_nil(user.parse_literal("no user here"))
    end)
end)

describe("comment bodies", function()
    it("keeps generics while stripping real HTML tags", function()
        local lines = comments.render({ {
            id = "c", author = "alice", rank = "1 kyu", created = "2026-06-05", score = 0, depth = 0,
            masked = false, body = "<p>Use <b>List&lt;string&gt;</b> or Map<K, V>, not ArrayList<></p>",
        } })
        assert.equals("  Use List<string> or Map<K, V>, not ArrayList<>", lines[2])
    end)
end)

describe("markdown.from_html", function()
    it("expands a sentinel nested inside a stashed <pre>", function()
        local out = markdown.from_html("<pre>use `a < b` here</pre>")
        assert.is_nil(out:find("CWMD", 1, true))
        assert.truthy(out:find("use `a < b` here", 1, true))
    end)
end)
