local kstate = require("codewars.kata.state")
local KataEditor = require("codewars-ui.kata_editor")

local KATA_ID = "6a63e7e085269ff93dc6332e"
local LANG_ID = "6a63e7e085269ff93dc6332f"

--- A loaded model in the shape api/kata_page produces.
local function model(opts)
    opts = opts or {}
    return {
        id = KATA_ID,
        language = "python",
        published = opts.published == true,
        languages = {
            python = {
                id = LANG_ID,
                name = "python",
                answer = "def hi():\n    return 1",
                setup = "# start",
                fixture = "test cases",
                example_fixture = "# sample",
                ["package"] = "",
            },
            -- a second language the workspace is NOT showing
            ruby = {
                id = "r1",
                name = "ruby",
                answer = "def hi; 1; end",
                setup = "",
                fixture = "rb",
                example_fixture = "",
            },
        },
        code_challenge = {
            name = "My Kata",
            category = "algorithms",
            estimated_rank = "-6",
            tags_text = "Strings",
            coauthors_wanted = true,
            description = "Do the thing.",
        },
        test_frameworks = { python = "cw-2" },
        fixtures_locked = false,
    }
end

--- An unmounted workspace: with no buffers, pane_content falls back to the
--- loaded values, which is exactly what we want for the pure logic.
local function workspace(opts)
    local ws = KataEditor:new(model(opts))
    ws:snapshot()
    return ws
end

describe("kata.state", function()
    it("starts a loaded model in the state its published flag implies", function()
        assert.are.equal("draft", kstate.of(false))
        assert.are.equal("published", kstate.of(true))
        assert.is_true(kstate.is_editable("draft"))
        assert.is_true(kstate.is_editable("published"))
        assert.is_true(kstate.is_locked("saving"))
        assert.is_true(kstate.is_locked("publishing"))
    end)

    it("reverts out of saving, because saving never changes publication", function()
        assert.are.equal("saving", kstate.step("draft", "save"))
        assert.are.equal("saving", kstate.step("published", "save"))
        assert.are.equal(kstate.REVERT, kstate.step("saving", "save_done"))
        assert.are.equal(kstate.REVERT, kstate.step("saving", "save_failed"))
    end)

    it("routes publish and unpublish", function()
        assert.are.equal("publishing", kstate.step("draft", "publish"))
        assert.are.equal("published", kstate.step("publishing", "publish_done"))
        assert.are.equal(kstate.REVERT, kstate.step("publishing", "publish_failed"))
        assert.are.equal("draft", kstate.step("published", "unpublish"))
    end)

    it("explains why an action is unavailable instead of failing silently", function()
        local ok, err = kstate.step("draft", "unpublish")
        assert.is_nil(ok)
        assert.truthy(err:match("isn't published"))

        ok, err = kstate.step("published", "publish")
        assert.is_nil(ok)
        assert.truthy(err:match("Already published"))

        for _, action in ipairs({ "edit", "save", "publish", "validate", "delete" }) do
            local blocked, why = kstate.step("saving", action)
            assert.is_nil(blocked, action .. " must be blocked while saving")
            assert.is_string(why)
        end
    end)
end)

describe("KataEditor panes", function()
    it("maps each pane to its field, with description coming off code_challenge", function()
        local ws = workspace()
        assert.are.equal("def hi():\n    return 1", ws:pane_content("answer"))
        assert.are.equal("# start", ws:pane_content("setup"))
        assert.are.equal("test cases", ws:pane_content("fixture"))
        assert.are.equal("# sample", ws:pane_content("example"))
        assert.are.equal("Do the thing.", ws:pane_content("description"))
    end)

    it("exposes the five panes in the website's order", function()
        local keys = vim.tbl_map(function(p)
            return p.key
        end, KataEditor.PANES)
        assert.are.same({ "answer", "setup", "fixture", "example", "description" }, keys)
    end)

    it("cycles panes and wraps around", function()
        local ws = workspace()
        local seen = {}
        -- show_pane needs a window; stub it and track the key it would show
        ws.show_pane = function(self, key)
            self.pane = key
            seen[#seen + 1] = key
        end
        ws:cycle_pane(1)
        ws:cycle_pane(1)
        ws.pane = "description"
        ws:cycle_pane(1) -- wraps forward
        ws.pane = "answer"
        ws:cycle_pane(-1) -- wraps backward
        assert.are.same({ "setup", "fixture", "answer", "description" }, seen)
    end)
end)

describe("KataEditor:is_dirty", function()
    it("is clean straight after a snapshot", function()
        assert.is_false(workspace():is_dirty())
    end)

    it("notices metadata edits, not just code edits", function()
        local ws = workspace()
        ws.cc.name = "Renamed"
        assert.is_true(ws:is_dirty())

        ws = workspace()
        ws.cc.estimated_rank = "-3"
        assert.is_true(ws:is_dirty())

        ws = workspace()
        ws.cc.coauthors_wanted = false
        assert.is_true(ws:is_dirty())

        ws = workspace()
        ws.cc.tags_text = "Strings, Algorithms"
        assert.is_true(ws:is_dirty())
    end)
end)

describe("KataEditor:build_model", function()
    it("keeps languages the workspace isn't showing", function()
        local body = workspace():build_model()
        assert.are.equal("python", body.language)
        assert.is_table(body.languages.ruby)
        assert.are.equal("def hi; 1; end", body.languages.ruby.answer)
        -- the per-language snippet id must survive, or the save creates a new one
        assert.are.equal(LANG_ID, body.languages.python.id)
    end)

    it("carries the live metadata and description into code_challenge", function()
        local ws = workspace()
        ws.cc.name = "Renamed"
        ws.cc.category = "games"
        local body = ws:build_model()
        assert.are.equal("Renamed", body.code_challenge.name)
        assert.are.equal("games", body.code_challenge.category)
        assert.are.equal("Do the thing.", body.code_challenge.description)
        assert.is_true(body.code_challenge.coauthors_wanted)
    end)

    it("feeds kata.save_payload without losing anything", function()
        local payload = require("codewars.api.kata").save_payload(workspace():build_model())
        assert.are.equal("python", payload.language)
        assert.are.equal(LANG_ID, payload.languages.python.id)
        assert.are.equal("# start", payload.languages.python.setup)
        assert.are.equal("# sample", payload.languages.python.example_fixture)
        assert.are.equal("-6", payload.code_challenge.estimated_rank)
        assert.are.equal("Strings", payload.code_challenge.tags_text)
    end)

    it("adopts a saved body as the new clean baseline", function()
        local ws = workspace()
        ws.cc.name = "Renamed"
        assert.is_true(ws:is_dirty())
        ws:adopt(ws:build_model())
        assert.is_false(ws:is_dirty())
        assert.are.equal("Renamed", ws.cc.name)
    end)
end)

describe("KataEditor:test_framework", function()
    it("uses the page's framework, falling back to the language default", function()
        assert.are.equal("cw-2", workspace():test_framework())

        local ws = KataEditor:new(model())
        ws.model.test_frameworks = {}
        assert.are.equal("cw-2", ws:test_framework()) -- python's default
    end)
end)

describe("KataEditor:header_lines", function()
    it("renders labels rather than raw slugs, and marks the active pane", function()
        local text = table.concat(workspace():header_lines(), "\n")
        assert.truthy(text:match("My Kata"))
        assert.truthy(text:match("Algorithms")) -- not "algorithms"
        assert.truthy(text:match("6 kyu")) -- not "-6"
        assert.truthy(text:match("Allow contributors: yes"))
        assert.truthy(text:match("`g1` Complete Solution"))
        assert.truthy(text:match("kata publish"))
    end)

    it("offers unpublish instead of publish once published", function()
        local text = table.concat(workspace({ published = true }):header_lines(), "\n")
        assert.truthy(text:match("kata unpublish"))
        assert.is_nil(text:match("kata publish"))
    end)
end)
