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
