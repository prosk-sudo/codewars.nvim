local attempt_api = require("codewars.api.attempt")
local Runner = require("codewars.runner")
local log = require("codewars.logger")

--- Kumite run wrapper (design §2.3, T11). Unlike kata, kumite has no
--- attempt/submit eligibility, no notify, and no finalize — running a
--- snippet against its fixture is a pure, side-effect-free runner call.
--- Reads live buffer content at call time (T9), never a stale model.
local M = {}

local BUSY = false

---@param ws cw.ui.Kumite
---@param result cw.ui.Console.ResultPopup
function M.run(ws, result)
    if BUSY then
        return log.warn("A kumite run is already in progress.")
    end
    -- The state machine says when a run is allowed (not while a save or
    -- publish is in flight); this was the one action that never asked it.
    if ws.state then
        local _, state_err = require("codewars.kumite.state").step(ws.state, "run")
        if state_err then
            return log.warn(state_err)
        end
    end

    local code = table.concat(vim.api.nvim_buf_get_lines(ws.bufnr, 0, -1, false), "\n")
    local fixture = ws:fixture_content()

    if vim.trim(fixture) == "" then
        result:handle_error({ msg = "This kumite has no test fixture to run against." })
        return
    end

    -- Snippet JSON carries no runtime version, so both fresh kumites and forks
    -- fall back to the language's Codewars default (else the runner picks a
    -- legacy runtime, e.g. Python 2.7 where `import codewars_test` fails).
    local version = ws.snippet.language_version
        or require("codewars.api.kumite").default_version(ws.lang)

    BUSY = true
    attempt_api.submit(
        code,
        ws.lang,
        fixture,
        ws.snippet.test_framework or "cw-2",
        nil, -- no relay/solution id: kumite runs are unattached
        version,
        { setup = ws.snippet.package or "" },
        function(res, err)
            BUSY = false

            if err then
                if err.auth then
                    require("codewars.cache.cookie").delete()
                end
                return result:handle_error(err)
            end

            local r = (res and res.result) or {}
            result:handle({
                valid = r.completed == true,
                summary = { passed = r.passed or 0, failed = r.failed or 0, errors = r.errors or 0 },
                output = Runner.build_output(res),
                wall_time = res and res.wallTime,
                success_msg = r.completed and "All tests passed! :)" or nil,
                reason = r.error,
            })
        end
    )
end

return M
