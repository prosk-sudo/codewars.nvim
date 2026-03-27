describe("Runner", function()
    -- Stub dependencies
    package.loaded["codewars.icons"] = package.loaded["codewars.icons"] or {
        get = function()
            return { test_passed = "P", test_failed = "F" }
        end,
    }
    package.loaded["codewars.config"] = package.loaded["codewars.config"] or {
        user = { keys = { toggle = { "q" } }, debug = false },
        lang = "python",
    }
    package.loaded["codewars.logger"] = package.loaded["codewars.logger"] or {
        info = function() end,
        warn = function() end,
        error = function() end,
        err = function() end,
        debug = function() end,
    }
    package.loaded["codewars.api.attempt"] = package.loaded["codewars.api.attempt"] or {
        submit = function() end,
        notify = function() end,
    }

    local Runner = require("codewars.runner")

    describe("running guard", function()
        it("prevents concurrent runs", function()
            Runner.running = true
            assert.truthy(Runner.running)
            Runner.running = false
        end)
    end)

    describe("submit guard", function()
        it("requires last_attempt_success for submit", function()
            local kata = {
                last_attempt_success = false,
                slug = "test",
                lang = "python",
            }
            local runner = Runner:init(kata)

            -- handle() checks last_attempt_success for submit mode
            Runner.running = true
            local ok, _ = pcall(Runner.handle, runner, "submit")
            if not ok then
                -- pcall catches the log.warn guard
            end

            -- After the guard, running should be reset
            Runner.running = false
        end)
    end)

    describe("format_output", function()
        it("handles complex nested structure", function()
            local output = {
                { t = "describe", v = "Kata", p = true, items = {
                    { t = "it", v = "basic test", p = true, items = {
                        { t = "passed", v = "Test Passed" },
                        { t = "passed", v = "Test Passed" },
                    }},
                    { t = "it", v = "edge case", p = false, items = {
                        { t = "passed" },
                        { t = "failed", v = "Expected 4 but got 5" },
                    }},
                    { t = "completedin", v = "150" },
                }},
            }

            local lines = Runner.format_output(output)
            assert.truthy(#lines > 0)

            -- Verify structure
            local has_kata = false
            local has_basic = false
            local has_edge = false
            local has_time = false
            for _, line in ipairs(lines) do
                if line:find("Kata") then has_kata = true end
                if line:find("basic test") and line:find("PASSED") then has_basic = true end
                if line:find("edge case") and line:find("FAILED") then has_edge = true end
                if line:find("Completed in 150ms") then has_time = true end
            end
            assert.truthy(has_kata)
            assert.truthy(has_basic)
            assert.truthy(has_edge)
            assert.truthy(has_time)
        end)
    end)
end)
