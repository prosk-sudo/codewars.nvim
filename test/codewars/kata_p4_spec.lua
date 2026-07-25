local kata = require("codewars.api.kata")

local KATA_ID = "6a63f4213479b7cdf94b6f0f" -- 24 hex
local LANG_ID = "6a63f4213479b7cdf94b6f10"

--- Re-require kata with a stubbed api.utils (kata binds utils at module load, so
--- the stub must be installed before the require). `handlers` maps a verb to a
--- {res=, err=} pair or a fn(endpoint, opts) -> res, err.
local function load_kata(handlers)
    local calls = {}
    local function verb(name)
        return function(endpoint, opts)
            calls[#calls + 1] = { method = name, endpoint = endpoint, body = opts and opts.body }
            local h = handlers[name]
            local res, err
            if type(h) == "function" then
                res, err = h(endpoint, opts)
            elseif type(h) == "table" then
                res, err = h.res, h.err
            end
            if opts and opts.callback then
                opts.callback(res, err)
            end
        end
    end
    -- Override only the HTTP verbs, keeping every other field of the real
    -- module (constants like HEX24 are read at load time). A wholesale
    -- replacement silently breaks the moment api.utils grows a non-verb field.
    package.loaded["codewars.api.utils"] = vim.tbl_extend("force",
        require("codewars.api.utils"),
        { post = verb("post"), get = verb("get"), delete = verb("delete") })
    package.loaded["codewars.api.kata"] = nil
    local mod = require("codewars.api.kata")
    package.loaded["codewars.api.kata"] = kata -- restore the shared instance
    return mod, calls
end

local function model()
    return {
        language = "python",
        languages = { python = { id = LANG_ID, answer = "def f():\n return 1", fixture = "F" } },
        code_challenge = { name = "T", category = "algorithms", tags_text = "a, b" },
    }
end

describe("kata.is_server_id", function()
    it("accepts a 24-hex kata id, rejects everything else", function()
        assert.is_true(kata.is_server_id(KATA_ID))
        assert.is_false(kata.is_server_id("local-1"))
        assert.is_false(kata.is_server_id(nil))
        assert.is_false(kata.is_server_id(string.rep("z", 24)))
    end)
end)

describe("kata pickers", function()
    it("maps Puzzles to the games category and 8 kyu to -8", function()
        local by_label = {}
        for _, c in ipairs(kata.CATEGORIES) do
            by_label[c.label] = c.value
        end
        assert.are.equal("games", by_label["Puzzles"])
        assert.are.equal("reference", by_label["Fundamentals"])
        assert.are.equal("bug_fixes", by_label["Bug Fixes"])

        assert.are.equal("", kata.RANKS[1].value) -- unset first
        local by_rank = {}
        for _, r in ipairs(kata.RANKS) do
            by_rank[r.label] = r.value
        end
        assert.are.equal("-8", by_rank["8 kyu"])
        assert.are.equal("-1", by_rank["1 kyu"])
    end)
end)

describe("kata.language_payload", function()
    it("defaults the version to the language default and sets name", function()
        local p = kata.language_payload("python", { id = LANG_ID, answer = "a=1" })
        assert.are.equal("python", p.name)
        assert.are.equal(LANG_ID, p.id)
        assert.are.equal("3.11", p.default_version) -- python default
        assert.are.equal("", p.setup)
        assert.are.equal("", p.example_fixture)
    end)

    it("keeps an explicit version", function()
        local p = kata.language_payload("python", { default_version = "3.8" })
        assert.are.equal("3.8", p.default_version)
    end)
end)

describe("kata.save_payload", function()
    it("wraps languages, echoes language, and builds code_challenge", function()
        local body = kata.save_payload(model())
        assert.are.equal("python", body.language)
        assert.is_table(body.languages.python)
        assert.are.equal(LANG_ID, body.languages.python.id)
        assert.are.equal("T", body.code_challenge.name)
        assert.are.equal("algorithms", body.code_challenge.category)
        assert.are.equal("a, b", body.code_challenge.tags_text)
    end)

    it("coerces coauthors_wanted to a boolean and defaults estimated_rank", function()
        local body = kata.save_payload({ code_challenge = {} })
        assert.is_false(body.code_challenge.coauthors_wanted)
        assert.are.equal("", body.code_challenge.estimated_rank)
        assert.are.equal("", body.language)
    end)
end)

describe("kata.render_error", function()
    it("extracts a rendered per-field validation error", function()
        local html = '<div class="alert-box error"><ul><li data-field="setup">Initial Solution is required</li></ul></div>'
        assert.are.equal("setup: Initial Solution is required", kata.render_error(html))
    end)

    it("flags an embedded languageErrors blob", function()
        local html = '...\\"languageErrors\\":{\\"python\\":[{\\"name\\":\\"setup\\",\\"message\\":\\"is blank\\"}]}...'
        assert.truthy(kata.render_error(html):match("blank"))
    end)

    it("returns nil for a clean render and for non-strings", function()
        assert.is_nil(kata.render_error('<div class="alert-box error is-hidden"><ul></ul></div>'))
        assert.is_nil(kata.render_error({ success = true }))
    end)
end)

describe("kata.save", function()
    it("POSTs /kata/{id} and reports success on a clean render", function()
        local mod, calls = load_kata({ post = { res = "<html>ok, no errors</html>" } })
        local got = "sentinel"
        mod.save(KATA_ID, model(), function(err) got = err end)
        assert.are.equal("post", calls[1].method)
        assert.are.equal("/kata/" .. KATA_ID, calls[1].endpoint)
        assert.is_table(calls[1].body.languages)
        assert.is_nil(got)
    end)

    it("surfaces a rendered validation error", function()
        local mod = load_kata({ post = { res = '<li data-field="name">Name is required</li>' } })
        local got
        mod.save(KATA_ID, model(), function(err) got = err end)
        assert.truthy(got.msg:match("name"))
    end)
end)

describe("kata.delete", function()
    it("DELETEs /kata/{id}", function()
        local mod, calls = load_kata({ delete = { res = 'Turbolinks.visit("/kata/new")' } })
        local got = "sentinel"
        mod.delete(KATA_ID, function(err) got = err end)
        assert.are.equal("delete", calls[1].method)
        assert.are.equal("/kata/" .. KATA_ID, calls[1].endpoint)
        assert.is_nil(got)
    end)

    it("treats a 404 as success, because destroy redirects onto the deleted kata", function()
        -- Confirmed live: the delete removes the kata and the followed
        -- redirect then reports 404. Surfacing that as an error told users a
        -- delete had failed when it had actually worked.
        local mod = load_kata({ delete = { err = { status = 404, msg = "http error 404" } } })
        local got = "sentinel"
        mod.delete(KATA_ID, function(err) got = err end)
        assert.is_nil(got)
    end)

    it("still reports a real failure", function()
        local mod = load_kata({ delete = { err = { status = 500, msg = "http error 500" } } })
        local got
        mod.delete(KATA_ID, function(err) got = err end)
        assert.are.equal(500, got.status)
    end)
end)

describe("kata.unpublish", function()
    it("POSTs /kata/{id}/unpublish", function()
        local mod, calls = load_kata({ post = { res = { success = true } } })
        local got = "sentinel"
        mod.unpublish(KATA_ID, function(err) got = err end)
        assert.are.equal("/kata/" .. KATA_ID .. "/unpublish", calls[1].endpoint)
        assert.is_nil(got)
    end)
end)

describe("kata.publish", function()
    it("POSTs publish, polls the deferred job, returns the kata url on success", function()
        local mod, calls = load_kata({
            post = { res = { success = true, dmid = "D1" } },
            get = { res = { html = "<html>clean</html>" } },
        })
        local got
        mod.publish(KATA_ID, model(), function(url, err) got = { url = url, err = err } end)
        assert.are.equal("/kata/" .. KATA_ID .. "/publish", calls[1].endpoint)
        assert.are.equal("/api/v1/deferred/D1", calls[2].endpoint)
        assert.is_nil(got.err)
        assert.are.equal("https://www.codewars.com/kata/" .. KATA_ID, got.url)
    end)

    it("surfaces a deferred validation failure", function()
        local mod = load_kata({
            post = { res = { success = true, dmid = "D2" } },
            get = { res = { html = '<li data-field="setup">Initial Solution is required</li>' } },
        })
        local got
        mod.publish(KATA_ID, model(), function(url, err) got = { url = url, err = err } end)
        assert.is_nil(got.url)
        assert.truthy(got.err.msg:match("setup"))
    end)

    it("rejects an immediate publish error with no dmid", function()
        local mod = load_kata({ post = { res = '<li data-field="name">Name is required</li>' } })
        local got
        mod.publish(KATA_ID, model(), function(url, err) got = { url = url, err = err } end)
        assert.is_nil(got.url)
        assert.truthy(got.err.msg:match("name"))
    end)
end)
