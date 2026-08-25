local urls = require("codewars.api.urls")
local api_utils = require("codewars.api.utils")

---@class cw.Api.Attempt
local attempt = {}

--- Get a short-lived runner authorization token.
---@param cb function callback(token?, err?)
function attempt.authorize(cb)
    api_utils.post(urls.authorize, {
        body = {},
        callback = function(res, err)
            if err then
                return cb(nil, err)
            end

            if res and res.token then
                cb(res.token)
            else
                cb(nil, { msg = "Failed to get runner authorization token" })
            end
        end,
    })
end

--- Submit code to the runner for testing using curl via jobstart.
---@param token string
---@param code string
---@param language string
---@param fixture string
---@param test_framework string
---@param solution_id string
---@param language_version string?
---@param opts? { setup?: string, ciphered?: string[] }
---@param cb function callback(result?, err?)
function attempt.run(token, code, language, fixture, test_framework, solution_id, language_version, opts, cb)
    local run_url = urls.runner_base .. urls.run

    local body = {
        language = language,
        code = code,
        fixture = fixture,
        testFramework = test_framework,
        relayId = solution_id,
    }

    if language_version then
        body.languageVersion = language_version
    end

    if opts then
        if opts.setup then body.setup = opts.setup end
        if opts.ciphered then body.ciphered = opts.ciphered end
    end

    local body_json = vim.json.encode(body)

    -- Write body to a temp file to avoid shell escaping issues
    local tmp = vim.fn.tempname()
    local f = io.open(tmp, "w")
    if not f then
        return cb(nil, { msg = "Failed to create temp file" })
    end
    f:write(body_json)
    f:close()

    local stdout_chunks = {}
    local stderr_chunks = {}
    -- Response headers go to a dump so the HTTP status can be classified:
    -- curl exits 0 on a 401 or 429, and without this the runner's JSON
    -- error body was decoded and handed to the caller as a test RESULT.
    local hdr = vim.fn.tempname()
    local page = require("codewars.api.page")

    local function cleanup()
        pcall(os.remove, tmp)
        pcall(os.remove, hdr)
    end

    local job = page.spawn({
        "curl", "-s",
        "-X", "POST",
        run_url,
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer " .. token,
        "-H", "User-Agent: Mozilla/5.0 (compatible; codewars.nvim)",
        "-d", "@" .. tmp,
        "-D", hdr,
        "--max-time", "30",
    }, {
        stdout_buffered = true,
        stderr_buffered = true,
        on_stdout = function(_, data)
            if data then
                vim.list_extend(stdout_chunks, data)
            end
        end,
        on_stderr = function(_, data)
            if data then
                vim.list_extend(stderr_chunks, data)
            end
        end,
        on_exit = vim.schedule_wrap(function(_, exit_code)
            local dump = page.slurp(hdr)
            cleanup()

            local out = table.concat(stdout_chunks, "")

            if exit_code ~= 0 then
                return cb(nil, { msg = ("curl exit code %d"):format(exit_code), code = exit_code, curl = true })
            end

            local status_err = page.status_err(page.parse_header_dump(dump))
            if status_err then
                return cb(nil, status_err)
            end

            if out == "" then
                return cb(nil, { msg = "Empty response from runner" })
            end

            local ok, decoded = require("codewars.api.utils").decode_json(out)
            if ok and type(decoded) == "table" then
                cb(decoded)
            else
                cb(nil, { msg = "Failed to parse runner response: " .. out:sub(1, 200) })
            end
        end),
    })

    -- The job never started (curl missing, spawn refused): on_exit will not
    -- run, so report it here or the runner waits forever.
    if not job then
        cleanup()
        cb(nil, { msg = "Could not start curl to reach the runner. Is curl installed?", curl = true })
    end
end

--- Notify Codewars server of a runner result (required for attempt to count).
---@param project_id string
---@param solution_id string
---@param body table { code, fixture, languageVersion, testFramework, token }
---@param cb? function
function attempt.notify(project_id, solution_id, body, cb)
    local endpoint = urls.notify:format(project_id, solution_id)
    api_utils.post(endpoint, {
        body = body,
        callback = cb or function() end,
    })
end

--- Full test flow: authorize, then run code on the runner.
---@param code string
---@param language string
---@param fixture string
---@param test_framework string
---@param solution_id string
---@param language_version string?
---@param opts? { setup?: string, ciphered?: string[] }
---@param cb function callback(result?, err?)
function attempt.submit(code, language, fixture, test_framework, solution_id, language_version, opts, cb)
    attempt.authorize(function(token, err)
        if err then
            return cb(nil, err)
        end

        attempt.run(token, code, language, fixture, test_framework, solution_id, language_version, opts, cb)
    end)
end

return attempt
