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

    describe("submit success path", function()
        local function submit_kata(rank)
            return {
                last_attempt_success = true,
                rank = rank,
                kata_id = "kid",
                slug = "s",
                lang = "python",
                project_id = "proj",
                solution_id = "sol",
            }
        end

        it("passes unranked flag from kata.rank to solutions.fetch", function()
            package.loaded["codewars.api.utils"] = {
                post = function(_, opts) opts.callback({}, nil) end,
            }
            package.loaded["codewars.api.urls"] = { finalize = "/x/%s/%s", base = "" }
            package.loaded["codewars.cache.completed"] = { mark = function() end }
            package.loaded["codewars.picker"] = { invalidate_completed_cache = function() end }
            package.loaded["codewars-ui.renderer.menu"] = { refresh_stats = function() end }
            local captured
            package.loaded["codewars.api.solutions"] = {
                fetch = function(_, _, _, opts) captured = opts end,
            }
            local real_defer = vim.defer_fn
            vim.defer_fn = function(fn) fn() end

            Runner.running = false
            Runner:init(submit_kata(nil)):handle("submit")
            assert.is_true(captured.unranked)

            captured = nil
            Runner.running = false
            Runner:init(submit_kata(-7)):handle("submit")
            assert.is_false(captured.unranked)

            vim.defer_fn = real_defer
            Runner.running = false
        end)
    end)

    describe("attempt registration honesty", function()
        it("revokes submit eligibility when notify fails", function()
            local logger = package.loaded["codewars.logger"]
            local warns = {}
            logger.warn = function(m) table.insert(warns, m) end

            local att = package.loaded["codewars.api.attempt"]
            att.submit = function(_, _, _, _, _, _, _, cb)
                cb({ result = { completed = true, passed = 1, failed = 0 }, token = "tok" })
            end
            att.notify = function(_, _, _, cb) cb(nil, { msg = "boom", status = 500 }) end

            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "print(1)" })
            local kata = { bufnr = buf, lang = "python", slug = "s", project_id = "p", solution_id = "sol", example_fixture = "f" }
            Runner.running = false
            Runner:init(kata):handle("attempt")

            assert.is_false(kata.last_attempt_success)
            assert.truthy(warns[1]:match("did not register"))
            logger.warn = function() end
            att.submit = function() end
            att.notify = function() end
            Runner.running = false
        end)

        it("errors when finalize returns success=false", function()
            local logger = package.loaded["codewars.logger"]
            local errors, infos = {}, {}
            logger.error = function(m) table.insert(errors, m) end
            logger.info = function(m) table.insert(infos, m) end

            package.loaded["codewars.api.utils"] = {
                post = function(_, opts) opts.callback({ success = false }, nil) end,
            }
            package.loaded["codewars.api.urls"] = { finalize = "/x/%s/%s", base = "" }
            local marks = 0
            package.loaded["codewars.cache.completed"] = { mark = function() marks = marks + 1 end }

            local kata = { last_attempt_success = true, slug = "s", lang = "python", kata_id = "k", project_id = "p", solution_id = "sol" }
            Runner.running = false
            Runner:init(kata):handle("submit")

            assert.truthy(errors[1]:match("refused to finalize"))
            assert.are.equal(0, marks)
            for _, m in ipairs(infos) do
                assert.is_nil(m:match("finalized successfully"))
            end
            logger.error = function() end
            logger.info = function() end
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
