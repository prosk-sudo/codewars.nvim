local Kumite = require("codewars-ui.kumite")

local ID = "6a6417267d0681224738b156"

local function workspace(state)
    return Kumite:new({
        id = ID,
        title = "musti",
        description = "good dog",
        language = "python",
        code = "print(1)",
        fixture = "test",
        ["package"] = "",
        test_framework = "cw-2",
        state = "draft",
    }, { state = state })
end

local function hints(state)
    return table.concat(workspace(state):keys_hint(), "\n")
end

describe("Kumite:keys_hint", function()
    it("offers convert on an editable workspace", function()
        -- convert was missing here: it is reachable from a saved draft but was
        -- listed nowhere in the workspace, so nothing told the user it existed.
        for _, state in ipairs({ "local_new", "local_fork", "server_draft" }) do
            local text = hints(state)
            assert.truthy(text:match("kumite convert"), state .. " must offer convert")
            assert.truthy(text:match("kumite save"), state .. " must offer save")
            assert.truthy(text:match("kumite publish"), state .. " must offer publish")
            assert.truthy(text:match("CW test"), state .. " must offer test")
        end
    end)

    it("offers unpublish and convert on your own published kumite", function()
        local text = hints("published")
        assert.truthy(text:match("kumite unpublish"))
        assert.truthy(text:match("kumite convert"))
        assert.truthy(text:match("kumite fork"))
    end)

    it("offers only fork and run on someone else's published kumite", function()
        -- published_view is another author's snippet: unpublish and convert
        -- would both fail, so listing them would be a lie.
        local text = hints("published_view")
        assert.truthy(text:match("kumite fork"))
        assert.is_nil(text:match("kumite unpublish"))
        assert.is_nil(text:match("kumite convert"))
        assert.is_nil(text:match("kumite save"))
    end)

    it("names a real command for every hint it prints", function()
        local commands = require("codewars.command").commands
        for _, state in ipairs({ "local_new", "local_fork", "server_draft", "published", "published_view" }) do
            for _, hint in ipairs(workspace(state):keys_hint()) do
                local sub = hint:match("`:CW kumite (%a+)`")
                if sub then
                    assert.is_table(commands.kumite[sub],
                        ("state %s advertises :CW kumite %s, which is not registered"):format(state, sub))
                end
            end
        end
    end)
end)

describe("Kumite initial state", function()
    local config = require("codewars.config")
    local real_user

    before_each(function()
        real_user = config.user.username
        config.user.username = "me"
    end)
    after_each(function()
        config.user.username = real_user
    end)

    local function snippet(overrides)
        return vim.tbl_extend("force", {
            id = ID, title = "t", description = "", language = "python",
            code = "x", fixture = "y", ["package"] = "", test_framework = "cw-2",
            state = "draft", author = "me",
        }, overrides or {})
    end

    it("opens YOUR OWN draft as editable, not read-only", function()
        -- REGRESSION: every open defaulted to published_view, so saving your
        -- own kumite was refused with "this is someone else's kumite" -- which
        -- also broke convert's rename retry, because that retry saves.
        local ws = Kumite:new(snippet({ state = "draft", author = "me" }))
        assert.are.equal("server_draft", ws.state)
        assert.is_true(require("codewars.kumite.state").is_editable(ws.state))
    end)

    it("opens your own published kumite as published, not a stranger's view", function()
        local ws = Kumite:new(snippet({ state = "published", author = "me" }))
        assert.are.equal("published", ws.state)
    end)

    it("treats a converted kumite as still yours and editable", function()
        local ws = Kumite:new(snippet({ state = "converted", author = "me" }))
        assert.are.equal("server_draft", ws.state)
    end)

    it("keeps someone else's kumite read-only", function()
        local ws = Kumite:new(snippet({ author = "someone_else" }))
        assert.are.equal("published_view", ws.state)
    end)

    it("stays read-only when authorship is unknown (signed-out list fallback)", function()
        -- built literally: vim.tbl_extend cannot override a key with nil (the
        -- key is simply absent), so `snippet({ author = nil })` would silently
        -- keep author = "me" and test nothing.
        local anon = snippet()
        anon.author = nil
        assert.are.equal("published_view", Kumite:new(anon).state)

        -- and with no signed-in user, even a matching author stays read-only
        config.user.username = ""
        assert.are.equal("published_view", Kumite:new(snippet({ author = "me" })).state)
    end)

    it("still honours an explicit state (:CW kumite new)", function()
        local ws = Kumite:new(snippet(), { state = "local_new" })
        assert.are.equal("local_new", ws.state)
    end)
end)
