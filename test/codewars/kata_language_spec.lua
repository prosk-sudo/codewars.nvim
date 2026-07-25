local KataEditor = require("codewars-ui.kata_editor")

local KATA_ID = "6a63e7e085269ff93dc6332e"

--- Mirrors the live shape: versionInfo covers EVERY language the editor
--- offers, not just the ones this kata already uses.
local function model()
    return {
        id = KATA_ID,
        language = "python",
        published = false,
        languages = {
            python = {
                id = "py1",
                name = "python",
                answer = "def hi(): return 1",
                setup = "# start",
                fixture = "py tests",
                example_fixture = "",
                ["package"] = "",
            },
        },
        code_challenge = {
            name = "My Kata",
            category = "algorithms",
            estimated_rank = "-6",
            tags_text = "",
            coauthors_wanted = true,
            description = "Do it.",
        },
        test_frameworks = { python = "cw-2" },
        version_info = {
            python = {
                { id = "3.8", label = "3.8", default = false },
                { id = "3.10", label = "3.10", default = false },
                { id = "3.11", label = "3.11", default = true },
            },
            ruby = {
                { id = "3.0", label = "3.0", default = true },
            },
        },
        fixtures_locked = false,
    }
end

local function workspace()
    local ws = KataEditor:new(model())
    ws:snapshot()
    return ws
end

describe("KataEditor runtime version", function()
    it("defaults to the runtime the editor marks default:true", function()
        assert.are.equal("3.11", workspace():version())
    end)

    it("honours an explicit pick, per language", function()
        local ws = workspace()
        ws:set_version("python", "3.8")
        assert.are.equal("3.8", ws:version("python"))
        assert.are.equal("3.0", ws:version("ruby")) -- untouched language keeps its default
    end)

    it("sends the chosen runtime on every language in the payload", function()
        local ws = workspace()
        ws:set_version("python", "3.10")
        local body = ws:build_model()
        assert.are.equal("3.10", body.languages.python.default_version)
    end)
end)

describe("KataEditor language switching", function()
    it("lists the kata's own languages first, then every other one it can add", function()
        local rows = workspace():available_languages()
        assert.are.equal("python", rows[1].lang)
        assert.is_true(rows[1].existing)
        assert.truthy(rows[1].label:match("in this kata"))

        local ruby
        for _, row in ipairs(rows) do
            if row.lang == "ruby" then
                ruby = row
            end
        end
        assert.is_not_nil(ruby, "a language the kata lacks must still be offerable")
        assert.is_false(ruby.existing)
        assert.truthy(ruby.label:match("add to this kata"))
    end)

    it("adds a missing language with an empty snippet id", function()
        local ws = workspace()
        ws:switch_language("ruby")
        assert.are.equal("ruby", ws.lang)
        -- empty id is how the save contract says "create this language"
        assert.are.equal("", ws.model.languages.ruby.id)
        assert.are.equal("", ws.model.languages.ruby.answer)
    end)

    it("seeds a new language's Test Cases from its starter template", function()
        local ws = workspace()
        ws:switch_language("ruby")
        local seeded = ws.model.languages.ruby.fixture
        assert.are.equal(require("codewars.kumite.fixtures").get("ruby"), seeded)
        assert.is_true(#seeded > 0, "an added language must not start with an empty fixture")
        -- and the pane reads it back, so the buffer shows the template
        assert.are.equal(seeded, ws:pane_content("fixture"))
    end)

    it("never overwrites an existing language's fixture when switching back", function()
        local ws = workspace()
        ws:switch_language("ruby")
        ws:switch_language("python")
        assert.are.equal("py tests", ws.model.languages.python.fixture)
    end)

    it("writes the outgoing language back so switching away loses nothing", function()
        local ws = workspace()
        ws:switch_language("ruby")
        ws:switch_language("python")
        assert.are.equal("def hi(): return 1", ws.model.languages.python.answer)
        assert.are.equal("py tests", ws.model.languages.python.fixture)
    end)

    it("keeps both languages in the save payload", function()
        local ws = workspace()
        ws:switch_language("ruby")
        local body = ws:build_model()
        assert.is_table(body.languages.python)
        assert.is_table(body.languages.ruby)
        assert.are.equal("ruby", body.language)
        assert.are.equal("3.0", body.languages.ruby.default_version)
    end)
end)
