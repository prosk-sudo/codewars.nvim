local curl = require("plenary.curl")
local log = require("codewars.logger")
local headers = require("codewars.api.headers")
local urls = require("codewars.api.urls")

---@class cw.err
---@field code? integer
---@field status? integer
---@field msg string
---@field lvl? integer

---@class cw.Api.Utils
local utils = {}

--- Lua pattern matching a Codewars id: 24 hex characters. Unanchored, so
--- callers can embed it (`"/kumite/(" .. HEX24 .. ")"`) or anchor it
--- themselves. Was typed out by hand in three modules; one copy means the
--- three cannot drift.
utils.HEX24 = ("%x"):rep(24)

---@param endpoint string
---@param opts? table
function utils.post(endpoint, opts)
    local options = vim.tbl_deep_extend("force", {
        endpoint = endpoint,
    }, opts or {})

    return utils.curl("post", options)
end

---@param endpoint string
---@param opts? table
function utils.get(endpoint, opts)
    local options = vim.tbl_deep_extend("force", {
        endpoint = endpoint,
    }, opts or {})

    return utils.curl("get", options)
end

---@param endpoint string
---@param opts? table
function utils.put(endpoint, opts)
    local options = vim.tbl_deep_extend("force", {
        endpoint = endpoint,
    }, opts or {})

    return utils.curl("put", options)
end

---@param endpoint string
---@param opts? table
function utils.delete(endpoint, opts)
    local options = vim.tbl_deep_extend("force", {
        endpoint = endpoint,
    }, opts or {})

    return utils.curl("delete", options)
end

---@private
---@param method string
---@param params table
--- Pull a header out of plenary's raw header list ("Key: value" strings).
---@param hdrs string[]?
---@param name string
---@return string?
function utils.header_value(hdrs, name)
    if type(hdrs) ~= "table" then return nil end
    local want = name:lower()
    for _, line in ipairs(hdrs) do
        local k, v = tostring(line):match("^([^:]+):%s*(.*)$")
        if k and k:lower() == want then
            return (v:gsub("%s+$", ""))
        end
    end
    -- Explicit: falling off the end returns ZERO values, and callers wrap
    -- this in tonumber(), which throws on no argument at all.
    return nil
end

utils.MAX_BACKOFF_MS = 60000

--- How long to wait before retrying. A 429 usually carries Retry-After and
--- the server knows its own limit better than we do; otherwise back off
--- exponentially rather than charging straight back into the same wall.
---@param err table?
---@param tries_left integer?
---@param max_tries integer?
---@return integer milliseconds
function utils.retry_delay_ms(err, tries_left, max_tries)
    local after = tonumber(err and err.retry_after)
    if after and after > 0 then
        return math.min(math.floor(after * 1000), utils.MAX_BACKOFF_MS)
    end
    local attempt = math.max(0, (max_tries or 3) - (tries_left or 0))
    return math.min(500 * (2 ^ attempt), 8000)
end

function utils.curl(method, params)
    local params_cpy = vim.deepcopy(params)

    params = vim.tbl_deep_extend("force", {
        headers = headers.get(),
        compressed = false,
        retry = 3,
        endpoint = "",
    }, params or {})

    local url = urls.base .. params.endpoint

    if type(params.body) == "table" then
        params.body = vim.json.encode(params.body)
    end

    local tries = params.retry
    local max_tries = params.retry
    -- 429 is retryable: the request was refused, not performed. Callers that
    -- must never repeat themselves (the destructive trainer dequeue) pass
    -- retry = 0 and are unaffected by this.
    local function should_retry(err)
        if not err or tries <= 0 then return false end
        if err.rate_limited then return true end
        return err.status ~= nil and err.status >= 500
    end

    if params.callback then
        local cb = vim.schedule_wrap(params.callback)
        params.callback = function(out, _)
            local res, err = utils.handle_res(out)

            if should_retry(err) then
                local wait = utils.retry_delay_ms(err, tries, max_tries)
                log.debug(("retry %d in %dms"):format(tries, wait))
                params_cpy.retry = tries - 1
                vim.schedule(function()
                    vim.defer_fn(function() utils.curl(method, params_cpy) end, wait)
                end)
            else
                cb(res, err)
            end
        end

        curl[method](url, params)
    else
        local out = curl[method](url, params)
        local res, err = utils.handle_res(out)

        if should_retry(err) then
            local wait = utils.retry_delay_ms(err, tries, max_tries)
            log.debug(("retry %d in %dms"):format(tries, wait))
            vim.wait(wait)
            params_cpy.retry = tries - 1
            return utils.curl(method, params_cpy)
        else
            return res, err
        end
    end
end

--- Decode-option policy for every Codewars JSON boundary: null object
--- fields become plain nil (never vim.NIL — the "compare userdata with
--- number" bug class); array nulls stay vim.NIL so sequences keep their
--- length. cache/utils.read_json mirrors these options inline (the cache
--- layer stays free of api dependencies).
utils.DECODE_OPTS = { luanil = { object = true } }

--- pcall-wrapped vim.json.decode with the shared option policy.
---@param str string
---@return boolean ok, any decoded_or_err
function utils.decode_json(str)
    return pcall(vim.json.decode, str, utils.DECODE_OPTS)
end

---@private
---@return table?, cw.err?
function utils.handle_res(out)
    local res, err

    log.debug(out)

    if not out then
        return nil, { msg = "No response received" }
    end

    if out.exit ~= 0 then
        err = {
            code = out.exit,
            msg = "curl failed",
        }
    elseif out.status == 429 then
        -- Rate limited. Codewars publishes no limit, so the only reliable
        -- signal is this response; carry Retry-After through so the retry
        -- waits the amount the server asked for.
        err = {
            code = 0,
            status = 429,
            rate_limited = true,
            retry_after = tonumber(utils.header_value(out.headers, "retry-after")),
            msg = "Codewars is rate limiting requests. Waiting before retrying.",
        }
    elseif out.status == 429 then
        -- Rate limited. Codewars publishes no limit, so this response is the
        -- only reliable signal; carry Retry-After through so the retry waits
        -- the amount the server actually asked for.
        err = {
            code = 0,
            status = 429,
            rate_limited = true,
            retry_after = tonumber(utils.header_value(out.headers, "retry-after")),
            msg = "Codewars is rate limiting requests. Waiting before retrying.",
        }
    elseif out.status == 401 or out.status == 403 then
        err = {
            code = 0,
            status = out.status,
            msg = "Session expired or invalid. Run :CW cookie to re-authenticate.",
            auth = true,
        }
    elseif out.status >= 300 then
        local ok, msg = pcall(function()
            local dec = vim.json.decode(out.body, utils.DECODE_OPTS)
            if dec.reason then
                return dec.reason
            end
            if dec.error then
                return dec.error
            end
            return "unknown error"
        end)

        res = out.body
        err = {
            code = 0,
            status = out.status,
            msg = "http error " .. out.status .. (ok and ("\n\n" .. msg) or ""),
        }
    else
        local ok, decoded = utils.decode_json(out.body)
        if ok then
            res = decoded
        else
            res = out.body
        end
    end

    return res, err
end

return utils
