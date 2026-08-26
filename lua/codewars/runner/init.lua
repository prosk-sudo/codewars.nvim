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
--- Build the console's output text from a runner response: the structured
--- `result.output` when present, else whatever landed on stderr/stdout.
---
--- Every caller that renders a run needs exactly this, and it had been copied
--- three times (here, kumite/runner, kata/runner) — which had already started
--- to drift. One implementation, so a fix reaches all of them.
---@param res table? decoded runner response
---@return string
function Runner.build_output(res)
    local r = (res and res.result) or {}
    local lines = {}
    if type(r.output) == "table" then
        vim.list_extend(lines, Runner.format_output(r.output))
    end
    if #lines == 0 then
        local fallback = (res and (res.stderr or res.stdout)) or ""
        if fallback ~= "" then
            vim.list_extend(lines, vim.split(fallback, "\n", { plain = true }))
        end
    end
    return table.concat(lines, "\n")
end

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
        if (kata._notify_pending or 0) > 0 then
            self:stop()
            return log.warn("Still registering your last attempt with Codewars — try :CW submit again in a moment.")
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

            -- A 200 with success=false means nothing was finalized (e.g. the
            -- passing attempt never registered server-side).
            if res and res.success == false then
                local msg = "Codewars refused to finalize this solution — the passing attempt may not have registered. Run :CW attempt, then :CW submit again."
                log.error(msg)
                if kata.console and kata.console.result then
                    kata.console.result:handle_error({ msg = msg })
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
            -- Solving a kata does not move the trainer's queue pointer. If
            -- this kata came from a focus, pop it so the next :CW focus
            -- serves a new one instead of the kata just finished.
            local focus_ok, focus_err = pcall(function()
                require("codewars.command").focus_kata_completed(kata)
            end)
            if not focus_ok then log.debug("focus advance failed: " .. tostring(focus_err)) end
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

                require("codewars-ui.popup.solutions").fetch_and_show(kata)
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

        -- The ids this run is submitted with. Read again at callback time
        -- they may already belong to another language's session.
        local project_id, solution_id = kata.project_id, kata.solution_id

        attempt_api.submit(
            code_str,
            kata.lang,
            fixture,
            kata.test_framework or "cw-2",
            solution_id,
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
                    local completed = r.completed == true
                    -- Only a full attempt (the kata's real fixture) can
                    -- unlock submit; a quick test runs against a fixture
                    -- the user can edit, so its pass proves nothing to
                    -- Codewars and finalize would complete nothing.
                    -- A run whose session ids changed underneath it (a
                    -- language switch mid-run) belongs to the old session
                    -- and must not unlock the new one.
                    local same_session = kata.project_id == project_id and kata.solution_id == solution_id
                    if mode == "attempt" and same_session then
                        kata.last_attempt_success = completed
                    end

                    local output = Runner.build_output(res)

                    local success_msg = nil
                    if r.completed then
                        success_msg = "You have passed all of the tests! :)"
                    end

                    local result = {
                        valid = completed,
                        summary = {
                            passed = passed,
                            failed = failed,
                            errors = errors,
                        },
                        output = output,
                        wall_time = res.wallTime,
                        success_msg = success_msg,
                        reason = r.error,
                    }

                    if kata.console and kata.console.result then
                        kata.console.result:handle(result)
                    end

                    -- Codewars only counts attempts it is notified of; a lost
                    -- notify makes the later finalize complete nothing, so a
                    -- failure here must revoke submit eligibility.
                    if res.token and project_id then
                        -- Only an attempt's registration gates submit: a
                        -- quick test is notified too, but it neither unlocks
                        -- nor may revoke an earlier attempt. A counter, not a
                        -- flag: stop() has already freed the runner, so two
                        -- notifies can overlap.
                        local gates_submit = mode == "attempt" and same_session
                        if gates_submit then
                            kata._notify_pending = (kata._notify_pending or 0) + 1
                        end
                        attempt_api.notify(project_id, solution_id, {
                            code = code_str,
                            fixture = fixture,
                            languageVersion = kata.language_version or "",
                            testFramework = kata.test_framework or "cw-2",
                            token = res.token,
                        }, function(nres, nerr)
                            if gates_submit then
                                kata._notify_pending = math.max(0, (kata._notify_pending or 1) - 1)
                            end
                            local not_registered = nerr ~= nil or (nres and nres.success == false)
                            -- Rechecked at reply time: a switch to another
                            -- language meanwhile means this notify belongs to
                            -- a session that is no longer the kata's.
                            local still_same = kata.project_id == project_id and kata.solution_id == solution_id
                            if not_registered and gates_submit and completed and still_same then
                                kata.last_attempt_success = false
                                log.warn("Codewars did not register this attempt"
                                    .. (nerr and nerr.msg and (" (" .. tostring(nerr.msg):gsub("\n.*", "") .. ")") or "")
                                    .. " — run :CW attempt again before submitting.")
                            end
                        end)
                    elseif mode == "attempt" and completed and same_session then
                        kata.last_attempt_success = false
                        log.warn("Missing runner token or project id — this attempt can't be registered on codewars.com. Run :CW attempt again.")
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
