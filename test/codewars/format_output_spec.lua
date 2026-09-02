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

    -- Codewars sends a multi-line message as ONE item: a C assertion carries
    -- the whole submitted array, and a loop that logs per iteration arrives as
    -- one blob. Prefixing the blob indented only its first physical line and
    -- dropped the rest to column zero -- and left embedded newlines inside
    -- single list entries, which is not what a list of lines means.
    describe("multi-line values", function()
        it("indents every line of a log, not just the first", function()
            local lines = Runner.format_output({
                { t = "describe", v = "suite", p = true, items = {
                    { t = "log", v = "one\ntwo\nthree" },
                }},
            })

            local got = {}
            for _, l in ipairs(lines) do
                if l:find("one") or l:find("two") or l:find("three") then
                    table.insert(got, l)
                end
            end
            assert.are.equal(3, #got)
            for _, l in ipairs(got) do
                assert.are.equal("  ", l:match("^(%s*)"),
                    ("every line keeps the nesting indent, got %q"):format(l))
            end
        end)

        it("aligns a failure message under its icon", function()
            local lines = Runner.format_output({
                { t = "failed", v = "< Incorrect Result >\n\n2048 is not between 1 and 2" },
            })

            assert.are.equal("F < Incorrect Result >", lines[1])
            -- Continuations line up past "F ", so the block reads as one unit.
            assert.are.equal("  2048 is not between 1 and 2", lines[3])
        end)

        it("aligns an error message under its label", function()
            local lines = Runner.format_output({
                { t = "error", v = "SyntaxError\n  at line 3" },
            })

            assert.are.equal("ERROR: SyntaxError", lines[1])
            assert.are.equal("         at line 3", lines[2])
        end)

        it("passes a whitespace-only separator through unpadded", function()
            -- Codewars separates the parts of a C assertion message with a
            -- lone space. Padding it would make a line of trailing whitespace;
            -- blanking it would drop a byte the old rendering kept.
            local lines = Runner.format_output({
                { t = "failed", v = "header\n \nbody" },
            })
            assert.are.equal(" ", lines[2], "the separator must survive verbatim")
            assert.are.equal("  body", lines[3])
        end)

        -- `..` coerced a number; vim.split raises on one. Nothing between
        -- vim.json.decode and here enforces that `v` is a string, and the
        -- throw would land in an unprotected scheduled callback, losing the
        -- whole run's output rather than one line.
        it("renders a non-string value instead of raising", function()
            for _, t in ipairs({ "log", "error", "passed", "failed" }) do
                local ok, lines = pcall(Runner.format_output, { { t = t, v = 42 } })
                assert.is_true(ok, ("a numeric value raised for t=%q"):format(t))
                assert.truthy(lines[1]:find("42", 1, true),
                    ("t=%q dropped the value: %q"):format(t, lines[1]))
            end
        end)

        it("never leaves a newline inside a single entry", function()
            local lines = Runner.format_output({
                { t = "describe", v = "suite", p = false, items = {
                    { t = "it", v = "case", p = false, items = {
                        { t = "log", v = "a\nb" },
                        { t = "failed", v = "x\ny" },
                        { t = "passed", v = "p\nq" },
                        { t = "error", v = "e\nf" },
                    }},
                }},
            })

            for i, l in ipairs(lines) do
                assert.is_nil(l:find("\n", 1, true),
                    ("entry %d still holds a newline: %q"):format(i, l))
            end
        end)
    end)
end)
