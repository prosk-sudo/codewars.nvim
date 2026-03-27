local log = require("codewars.logger")
local attempt_api = require("codewars.api.attempt")
local config = require("codewars.config")

---@class cw.Runner
---@field kata cw.ui.Kata
local Runner = {}
Runner.__index = Runner

Runner.running = false

---@param self cw.Runner
---@param mode string "test"|"attempt"|"submit"
Runner.run = vim.schedule_wrap(function(self, mode)
    if Runner.running then
        return log.warn("Runner is busy")
    end

    local ok, err = pcall(Runner.handle, self, mode)
    if not ok then
        self:stop()
        log.error(tostring(err))
    end
end)

function Runner:stop()
    Runner.running = false
end

--- Format structured runner output into readable lines
---@param output table[]
---@return string[]
function Runner.format_output(output)
    local icons = require("codewars.icons").get()
    local lines = {}

    local function walk(items, indent)
        indent = indent or 0
        local prefix = string.rep("  ", indent)
        for _, item in ipairs(items) do
            if item.t == "describe" then
                local status = item.p and "" or " [FAILED]"
                table.insert(lines, prefix .. (item.v or "") .. status)
                if item.items then
                    walk(item.items, indent + 1)
                end
                table.insert(lines, "")
            elseif item.t == "it" then
                local passed, failed = 0, 0
                if item.items then
                    for _, sub in ipairs(item.items) do
                        if sub.t == "passed" then passed = passed + 1 end
                        if sub.t == "failed" then failed = failed + 1 end
                    end
                end
                local status = item.p and "PASSED" or "FAILED"
                local counts = ("(%d of %d Assertions)"):format(passed, passed + failed)
                table.insert(lines, prefix .. status .. ": " .. (item.v or "") .. " " .. counts)
                if item.items then
                    walk(item.items, indent + 1)
                end
                table.insert(lines, "")
            elseif item.t == "completedin" then
                table.insert(lines, prefix .. "Completed in " .. (item.v or "?") .. "ms")
                table.insert(lines, "")
            elseif item.t == "passed" then
                local val = item.v or ""
                if val == "" or val == "Test Passed" then
                    table.insert(lines, prefix .. icons.test_passed .. " Test Passed")
                else
                    table.insert(lines, prefix .. icons.test_passed .. " " .. val)
                end
                table.insert(lines, "")
            elseif item.t == "failed" then
                local val = item.v or ""
                if val == "" or val == "Test Failed" then
                    table.insert(lines, prefix .. icons.test_failed .. " Test Failed")
                else
                    table.insert(lines, prefix .. icons.test_failed .. " " .. val)
                end
                table.insert(lines, "")
            elseif item.t == "error" then
                table.insert(lines, prefix .. "ERROR: " .. (item.v or ""))
            elseif item.t == "log" then
                table.insert(lines, prefix .. (item.v or ""))
            end
        end
    end

    walk(output)
    return lines
end

---@param mode string "test"|"attempt"|"submit"
function Runner:handle(mode)
    Runner.running = true
    local kata = self.kata

    if mode == "submit" then
        if not kata.last_attempt_success then
            self:stop()
            return log.warn("Cannot submit: last attempt was not successful")
        end

        local api_utils = require("codewars.api.utils")
        local urls = require("codewars.api.urls")
        local endpoint = urls.finalize:format(kata.project_id, kata.solution_id)
        api_utils.post(endpoint, { body = {}, callback = function(res, err)
            self:stop()

            if err then
                log.err(err)
                if kata.console and kata.console.result then
                    kata.console.result:handle_error(err)
                end
                return
            end

            log.info("Kata finalized successfully!")
            kata.finalized = true
            local ok, mark_err = pcall(function()
                require("codewars.cache.completed").mark(kata.kata_id, kata.slug, kata.lang)
                require("codewars.picker").invalidate_completed_cache()
                require("codewars-ui.renderer.menu").refresh_stats()
            end)
            if not ok then log.error("Failed to mark completed: " .. tostring(mark_err)) end
            if kata.console and kata.console.result then
                kata.console.result:handle({
                    valid = true,
                    summary = { passed = 0, failed = 0, errors = 0 },
                    output = "Solution submitted successfully!",
                })
            end

            -- Show solutions after a brief delay so user can see the submit result
            vim.defer_fn(function()
                if kata.console then
                    kata.console:hide()
                end

                local solutions_api = require("codewars.api.solutions")
                solutions_api.fetch(kata.kata_id, kata.lang, function(solutions)
                    if solutions and #solutions > 0 then
                        local Solutions = require("codewars-ui.popup.solutions")
                        Solutions:new(solutions, kata.lang):show()
                    else
                        log.info("Solutions will be available once the kata is fully completed on codewars.com. Use :CW solutions to check later.")
                    end
                end)
            end, 1500)
        end })
    else
        local code = vim.api.nvim_buf_get_lines(kata.bufnr, 0, -1, false)
        local code_str = table.concat(code, "\n")

        local fixture, opts
        if mode == "attempt" then
            -- Attempt: encrypted fixture + setup, both ciphered
            fixture = kata.fixture or kata.example_fixture or ""
            opts = {
                setup = kata.package or "",
                ciphered = { "setup", "fixture" },
            }
            log.info("Attempting solution...")
        else
            -- Test: user-editable example fixture, only setup ciphered
            fixture = kata.example_fixture or ""
            if kata.testcase_split then
                local tc = kata.testcase_split:content()
                if tc and tc ~= "" then
                    fixture = tc
                end
            end
            opts = {
                setup = kata.package or "",
                ciphered = { "setup" },
            }
            log.info("Running tests...")
        end

        attempt_api.submit(
            code_str,
            kata.lang,
            fixture,
            kata.test_framework or "cw-2",
            kata.solution_id,
            kata.language_version,
            opts,
            function(res, err)
                self:stop()

                if err then
                    -- Clear session cache on auth errors so next train gets fresh session
                    if err.auth then
                        local session_cache = require("codewars.cache.session")
                        session_cache.delete(kata.slug, kata.lang)
                    end
                    log.err(err)
                    if kata.console and kata.console.result then
                        kata.console.result:handle_error(err)
                    end
                    return
                end

                if res then
                    if config.user.debug then
                        log.info("Runner response keys: " .. table.concat(vim.tbl_keys(res), ", "))
                        if res.result then
                            log.info("Result keys: " .. table.concat(vim.tbl_keys(res.result), ", "))
                        end
                    end

                    local r = res.result or {}
                    local passed = r.passed or 0
                    local failed = r.failed or 0
                    local errors = r.errors or 0
                    kata.last_attempt_success = r.completed == true

                    local output_lines = {}

                    if r.output and type(r.output) == "table" then
                        vim.list_extend(output_lines, Runner.format_output(r.output))
                    end

                    -- Fallback: use stderr/stdout when no structured output
                    if #output_lines == 0 then
                        local fallback = res.stderr or res.stdout or ""
                        if fallback ~= "" then
                            for _, line in ipairs(vim.split(fallback, "\n", { plain = true })) do
                                table.insert(output_lines, line)
                            end
                        end
                    end

                    local success_msg = nil
                    if r.completed then
                        success_msg = "You have passed all of the tests! :)"
                    end

                    local result = {
                        valid = kata.last_attempt_success,
                        summary = {
                            passed = passed,
                            failed = failed,
                            errors = errors,
                        },
                        output = table.concat(output_lines, "\n"),
                        wall_time = res.wallTime,
                        success_msg = success_msg,
                        reason = r.error,
                    }

                    if kata.console and kata.console.result then
                        kata.console.result:handle(result)
                    end

                    if res.token and kata.project_id then
                        attempt_api.notify(kata.project_id, kata.solution_id, {
                            code = code_str,
                            fixture = fixture,
                            languageVersion = kata.language_version or "",
                            testFramework = kata.test_framework or "cw-2",
                            token = res.token,
                        })
                    end
                end
            end
        )
    end
end

---@param kata cw.ui.Kata
---@return cw.Runner
function Runner:init(kata)
    return setmetatable({ kata = kata }, self)
end

return Runner
