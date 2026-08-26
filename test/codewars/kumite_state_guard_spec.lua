local Kumite = require("codewars-ui.kumite")

local OWN_ID = "6a63e7e085269ff93dc6332e"

local function workspace(state)
    return Kumite:new({
        id = OWN_ID,
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

local function capture_warnings()
    local log = require("codewars.logger")
    local real, seen = log.warn, {}
    log.warn = function(msg)
        seen[#seen + 1] = msg
    end
    return seen, function()
        log.warn = real
    end
end

describe("Kumite state guards", function()
    it("server_id is nil while viewing someone else's kumite", function()
        assert.is_nil(workspace("published_view"):server_id())
        assert.equals(OWN_ID, workspace("published"):server_id())
    end)

    it("convert refuses a published_view without touching the API", function()
        local real = package.loaded["codewars.api.kumite"]
        local calls = {}
        package.loaded["codewars.api.kumite"] = {
            is_server_id = function()
                return true
            end,
            convert_to_kata = function(id)
                calls[#calls + 1] = id
            end,
        }
        local warned, restore = capture_warnings()
        workspace("published_view"):convert()
        restore()
        package.loaded["codewars.api.kumite"] = real
        assert.same({}, calls)
        assert.equals(1, #warned)
    end)

    it("set_state locks the buffers whenever the state is not editable", function()
        local ws = workspace("local_new")
        local locked = {}
        ws.set_buffers_locked = function(_, flag)
            locked[#locked + 1] = flag
        end
        ws:set_state("saving")
        ws:set_state("local_new")
        assert.same({ true, false }, locked)
    end)
end)

describe("kumite.runner asks the state machine", function()
    local real_attempt, real_runner

    before_each(function()
        real_attempt = package.loaded["codewars.api.attempt"]
        real_runner = package.loaded["codewars.kumite.runner"]
        package.loaded["codewars.kumite.runner"] = nil
    end)

    after_each(function()
        package.loaded["codewars.api.attempt"] = real_attempt
        package.loaded["codewars.kumite.runner"] = real_runner
    end)

    it("refuses to run while a save is in flight", function()
        local submitted = false
        package.loaded["codewars.api.attempt"] = {
            submit = function()
                submitted = true
            end,
        }
        local runner = require("codewars.kumite.runner")
        local warned, restore = capture_warnings()
        runner.run({ state = "saving" }, {})
        restore()
        assert.is_false(submitted)
        assert.equals(1, #warned)
    end)
end)
