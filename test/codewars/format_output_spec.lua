describe("Runner.format_output", function()
    -- Stub icons before loading runner
    package.loaded["codewars.icons"] = {
        get = function()
            return {
                test_passed = "P",
                test_failed = "F",
            }
        end,
    }

    -- Stub config and logger to avoid full plugin init
    package.loaded["codewars.config"] = {
        user = { keys = { toggle = { "q" } }, debug = false },
        lang = "python",
    }
    package.loaded["codewars.logger"] = {
        info = function() end,
        warn = function() end,
        error = function() end,
        debug = function() end,
    }
    package.loaded["codewars.api.attempt"] = {}

    local Runner = require("codewars.runner")

    it("formats passed test", function()
        local output = {
            { t = "passed", v = "Test Passed" },
        }
        local lines = Runner.format_output(output)
        assert.truthy(#lines > 0)
        assert.truthy(lines[1]:find("P Test Passed"))
    end)

    it("formats failed test", function()
        local output = {
            { t = "failed", v = "Expected 4 but got 5" },
        }
        local lines = Runner.format_output(output)
        assert.truthy(lines[1]:find("F Expected 4 but got 5"))
    end)

    it("formats describe block", function()
        local output = {
            { t = "describe", v = "multiply", p = true, items = {
                { t = "it", v = "should work", p = true, items = {
                    { t = "passed", v = "Test Passed" },
                }},
            }},
        }
        local lines = Runner.format_output(output)
        assert.truthy(lines[1]:find("multiply"))
        -- "it" block should show PASSED with assertion count
        local found_passed = false
        for _, line in ipairs(lines) do
            if line:find("PASSED") and line:find("should work") then
                found_passed = true
            end
        end
        assert.truthy(found_passed)
    end)

    it("formats failed describe block", function()
        local output = {
            { t = "describe", v = "multiply", p = false },
        }
        local lines = Runner.format_output(output)
        assert.truthy(lines[1]:find("%[FAILED%]"))
    end)

    it("formats completedin", function()
        local output = {
            { t = "completedin", v = "42" },
        }
        local lines = Runner.format_output(output)
        assert.truthy(lines[1]:find("Completed in 42ms"))
    end)

    it("formats error item", function()
        local output = {
            { t = "error", v = "SyntaxError: unexpected token" },
        }
        local lines = Runner.format_output(output)
        assert.truthy(lines[1]:find("ERROR: SyntaxError"))
    end)

    it("formats log item", function()
        local output = {
            { t = "log", v = "debug output here" },
        }
        local lines = Runner.format_output(output)
        assert.truthy(lines[1]:find("debug output here"))
    end)

    it("handles nested indentation", function()
        local output = {
            { t = "describe", v = "outer", p = true, items = {
                { t = "describe", v = "inner", p = true, items = {
                    { t = "passed", v = "deep test" },
                }},
            }},
        }
        local lines = Runner.format_output(output)
        -- inner should be indented more than outer
        local outer_indent, inner_indent
        for _, line in ipairs(lines) do
            if line:find("outer") then
                outer_indent = #(line:match("^(%s*)") or "")
            end
            if line:find("inner") then
                inner_indent = #(line:match("^(%s*)") or "")
            end
        end
        assert.is_not_nil(outer_indent)
        assert.is_not_nil(inner_indent)
        assert.truthy(inner_indent > outer_indent)
    end)

    it("handles empty output", function()
        local lines = Runner.format_output({})
        assert.are.equal(0, #lines)
    end)

    it("counts assertions in it block", function()
        local output = {
            { t = "it", v = "test", p = true, items = {
                { t = "passed" },
                { t = "passed" },
                { t = "failed" },
            }},
        }
        local lines = Runner.format_output(output)
        local found = false
        for _, line in ipairs(lines) do
            if line:find("%(2 of 3 Assertions%)") then
                found = true
            end
        end
        assert.truthy(found)
    end)
end)
