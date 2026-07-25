local Kumite = require("codewars-ui.kumite")

local PARENT_ID = "6a6417267d0681224738b156"
local OWN_ID = "6a63e7e085269ff93dc6332e"

local function workspace(state, id)
    return Kumite:new({
        id = id or PARENT_ID,
        title = "musti",
        description = "",
        language = "python",
        code = "print(1)",
        fixture = "test",
        ["package"] = "",
        test_framework = "cw-2",
        state = "published",
    }, { state = state })
end

--- Capture whatever the workspace would send to the API, without sending it.
local function record_calls()
    local calls = {}
    package.loaded["codewars.api.kumite"] = {
        is_server_id = function(id)
            return type(id) == "string" and #id == 24 and id:match("^%x+$") ~= nil
        end,
        unpublish = function(id)
            calls[#calls + 1] = { verb = "unpublish", id = id }
        end,
        convert_to_kata = function(id)
            calls[#calls + 1] = { verb = "convert", id = id }
        end,
    }
    return calls
end

describe("Kumite:server_id", function()
    local real
    before_each(function()
        real = package.loaded["codewars.api.kumite"]
    end)
    after_each(function()
        package.loaded["codewars.api.kumite"] = real
    end)

    it("is nil for an unsaved fork, because snippet.id is still the PARENT's", function()
        record_calls()
        -- fork() deliberately leaves snippet.id pointing at the parent until
        -- the first save; acting on it would mutate the original kumite.
        assert.is_nil(workspace("local_fork"):server_id())
        assert.is_nil(workspace("local_new"):server_id())
    end)

    it("is the workspace's own id once it exists on codewars.com", function()
        record_calls()
        assert.are.equal(OWN_ID, workspace("server_draft", OWN_ID):server_id())
        assert.are.equal(OWN_ID, workspace("published", OWN_ID):server_id())
    end)
end)

describe("account mutations never target the parent", function()
    local real
    before_each(function()
        real = package.loaded["codewars.api.kumite"]
    end)
    after_each(function()
        package.loaded["codewars.api.kumite"] = real
    end)

    it("refuses to unpublish or convert from an unsaved fork", function()
        local calls = record_calls()
        local ws = workspace("local_fork")

        ws:unpublish()
        ws:convert()

        assert.are.equal(0, #calls,
            "an unsaved fork must not send ANY mutation — it would hit the parent kumite")
    end)

    it("targets its own id once saved", function()
        local calls = record_calls()
        workspace("published", OWN_ID):unpublish()
        assert.are.equal(1, #calls)
        assert.are.equal("unpublish", calls[1].verb)
        assert.are.equal(OWN_ID, calls[1].id)
    end)
end)
