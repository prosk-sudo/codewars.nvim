local attempt = require("codewars.api.attempt")
local api_utils = require("codewars.api.utils")

--- Kumite publish flow (contract live-captured 2026-07-24).
--- Two steps: (1) run the saved code+fixture on the runner with relayId = the
--- snippet id to obtain a signed "coderunner" token proving the tests pass,
--- then (2) POST /kumite/{id}/publish with {token, run_result}. Publishing
--- makes the kumite public — callers gate it behind a saved draft, passing
--- tests, and a confirmation prompt.
local M = {}

local BUSY = false

--- @param r table? runner result object
--- @return boolean # tests all passed and completed
local function all_passed(r)
    return type(r) == "table"
        and r.completed == true
        and (r.failed or 0) == 0
        and (r.errors or 0) == 0
end

--- Run then publish. cb(url, err) — url is the public kumite URL on success.
---@param args { id: string, language: string, code: string, fixture: string, test_framework: string?, language_version: string?, setup: string? }
---@param cb fun(url: string?, err: cw.err?)
function M.run_and_publish(args, cb)
    if BUSY then
        return cb(nil, { msg = "A publish is already in progress." })
    end
    BUSY = true

    attempt.submit(
        args.code,
        args.language,
        args.fixture,
        args.test_framework or "cw-2",
        args.id, -- relayId: publish binds the run to this snippet
        args.language_version,
        { setup = args.setup or "" },
        function(res, err)
            if err then
                BUSY = false
                return cb(nil, err)
            end
            local r = res and res.result
            if type(res) ~= "table" or type(res.token) ~= "string" or not all_passed(r) then
                BUSY = false
                return cb(nil, { msg = "Tests must pass before publishing — run :CW test and fix any failures first." })
            end

            -- The server re-validates the token against this exact result blob.
            local run_result = vim.json.encode({ response = { result = r } })
            api_utils.post(("/kumite/%s/publish"):format(args.id), {
                body = { token = res.token, run_result = run_result },
                callback = function(pres, perr)
                    BUSY = false
                    if perr then
                        return cb(nil, perr)
                    end
                    if type(pres) ~= "table" or pres.success ~= true then
                        local why = (type(pres) == "table" and pres.validToken == false)
                            and " (runner token rejected)" or ""
                        return cb(nil, { msg = "Codewars rejected the publish" .. why .. "." })
                    end
                    cb(("https://www.codewars.com/kumite/%s"):format(args.id), nil)
                end,
            })
        end
    )
end

return M
