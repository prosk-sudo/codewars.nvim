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
utils.BASE_BACKOFF_MS = 500
utils.MAX_EXP_BACKOFF_MS = 8000
-- A synchronous retry blocks the editor outright, so it never honors a long
-- Retry-After in full. Async retries are free to wait the whole thing.
utils.MAX_SYNC_WAIT_MS = 5000

--- How long to wait before retrying. A 429 usually carries Retry-After and
--- the server knows its own limit better than we do; otherwise back off
--- exponentially rather than charging straight back into the same wall.
---
--- `attempt` is how many retries have ALREADY happened (0 on the first).
--- It is passed explicitly rather than derived from the remaining-tries
--- counter: that counter shrinks on every recursion, so deriving from it
--- made every wait the same 500ms and the backoff never actually grew.
---@param err table?
---@param attempt integer? retries already performed, 0-based
---@return integer milliseconds
function utils.retry_delay_ms(err, attempt)
    local after = tonumber(err and err.retry_after)
    if after and after > 0 then
        return math.min(math.floor(after * 1000), utils.MAX_BACKOFF_MS)
    end

    local base = math.min(
        utils.BASE_BACKOFF_MS * (2 ^ math.max(0, attempt or 0)),
        utils.MAX_EXP_BACKOFF_MS
    )

    -- The server sent Retry-After in a form we could not read (RFC allows an
    -- HTTP-date, not just seconds). It asked for a wait, so start from the
    -- longest backoff rather than the shortest.
    if err and err.retry_after_raw and not after then
        base = utils.MAX_EXP_BACKOFF_MS
    end

    -- Jitter. The cache build fires a batch of requests together, so without
    -- it every worker in a 429'd batch wakes at the identical moment and
    -- replays the same burst into the same limiter window.
    return math.floor(base * (0.75 + math.random() * 0.5))
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
    -- Carried across recursions so the backoff can actually grow. plenary
    -- ignores opt keys it does not know, same as the `endpoint` key above.
    local attempt = params.retry_attempt or 0
    -- A 429 means the request was REFUSED, so repeating it is normally safe.
    -- "Normally" is not good enough for a POST that registers a solve,
    -- publishes a kata or saves a draft: we cannot prove the server did no
    -- work before refusing, and a duplicate there is user-visible. Before
    -- this change nothing retried a 429 at all, so auto-retrying every
    -- mutating call would be new exposure introduced by a rate-limit fix.
    -- GET retries automatically; anything else must opt in explicitly with
    -- retry_rate_limited = true.
    local retry_rate_limited = params.retry_rate_limited
    if retry_rate_limited == nil then
        retry_rate_limited = (method == "get")
    end

    local function should_retry(err)
        if not err or tries <= 0 then return false end
        if err.rate_limited then return retry_rate_limited end
        return err.status ~= nil and err.status >= 500
    end

    if params.callback then
        local cb = vim.schedule_wrap(params.callback)
        params.callback = function(out, _)
            local res, err = utils.handle_res(out)

            if should_retry(err) then
                local wait = utils.retry_delay_ms(err, attempt)
                log.debug(("retry %d in %dms"):format(tries, wait))
                params_cpy.retry = tries - 1
                params_cpy.retry_attempt = attempt + 1
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
            -- Clamped: this blocks the UI thread, and Retry-After is
            -- server-controlled, so an unclamped wait would let the remote
            -- freeze the editor for a minute at a time.
            local wait = math.min(utils.retry_delay_ms(err, attempt), utils.MAX_SYNC_WAIT_MS)
            log.debug(("retry %d in %dms (sync)"):format(tries, wait))
            vim.wait(wait)
            params_cpy.retry = tries - 1
            params_cpy.retry_attempt = attempt + 1
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
            -- Kept even when unparseable (HTTP-date form) so the backoff can
            -- tell "server asked for a wait we could not read" apart from
            -- "server said nothing".
            retry_after_raw = utils.header_value(out.headers, "retry-after"),
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
