local attempt_api = require("codewars.api.attempt")
local Runner = require("codewars.runner")
local log = require("codewars.logger")

--- Kata "Validate Solution" (design KP2). The editor's Validate button is an
--- ordinary runner call — the same path as `:CW test` — so this reuses the run
--- machinery instead of adding a second one. Pure and side-effect-free: it
--- proves the solution passes its own fixture before you ask the server to
--- publish (publish re-runs it server-side and rejects a failing pair).
---
--- Reads live buffer content at call time, never the loaded model, so what you
--- see in the panes is what gets run.
local M = {}

local BUSY = false

---@param ws cw.ui.KataEditor
---@param result cw.ui.Console.ResultPopup
function M.run(ws, result)
    if BUSY then
        return log.warn("A kata validation is already in progress.")
    end

    local code = ws:pane_content("answer")
    local fixture = ws:pane_content("fixture")

    if vim.trim(code) == "" then
        return result:handle_error({ msg = "Write a Complete Solution before validating." })
    end
    if vim.trim(fixture) == "" then
        return result:handle_error({ msg = "This kata has no Test Cases to validate against." })
    end

    local kata_api = require("codewars.api.kata")

    BUSY = true
    attempt_api.submit(
        code,
        ws.lang,
        fixture,
        ws:test_framework(),
        nil, -- no relay/solution id: authoring runs are unattached
        kata_api.default_version(ws.lang),
        { setup = ws:pane_content("setup") },
        function(res, err)
            BUSY = false

            if err then
                if err.auth then
                    require("codewars.cache.cookie").delete()
                end
                return result:handle_error(err)
            end

            local r = (res and res.result) or {}
            local output_lines = {}
            if type(r.output) == "table" then
                vim.list_extend(output_lines, Runner.format_output(r.output))
            end
            if #output_lines == 0 then
                local fallback = (res and (res.stderr or res.stdout)) or ""
                if fallback ~= "" then
                    vim.list_extend(output_lines, vim.split(fallback, "\n", { plain = true }))
                end
            end

            result:handle({
                valid = r.completed == true,
                summary = { passed = r.passed or 0, failed = r.failed or 0, errors = r.errors or 0 },
                output = table.concat(output_lines, "\n"),
                wall_time = res and res.wallTime,
                success_msg = r.completed and "Solution passes its own tests — ready to publish." or nil,
                reason = r.error,
            })
        end
    )
end

return M
