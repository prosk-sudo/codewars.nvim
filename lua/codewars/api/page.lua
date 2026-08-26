local headers_mod = require("codewars.api.headers")

---@class cw.Api.Page
local page = {}

local ENTITIES = {
    ["&lt;"] = "<",
    ["&gt;"] = ">",
    ["&amp;"] = "&",
    ["&quot;"] = '"',
    ["&#39;"] = "'",
    ["&#x27;"] = "'",
    ["&#x2F;"] = "/",
    ["&nbsp;"] = " ",
}

--- Decode the common HTML entities found in scraped Codewars pages.
--- Single-pass table gsub: unknown entities pass through unchanged.
---@param s string
---@return string
function page.unescape(s)
    return (s:gsub("&(#?[%w]+);", function(name)
        local known = ENTITIES["&" .. name .. ";"]
        if known then
            return known
        end
        -- Numeric references (&#8217; / &#x2019;) are the common form in
        -- clan names and comments and were leaking through as literal text.
        local dec = name:match("^#(%d+)$")
        local hex = name:match("^#[xX](%x+)$")
        local code = dec and tonumber(dec) or hex and tonumber(hex, 16)
        if code and code > 0 and code <= 0x10FFFF then
            return vim.fn.nr2char(code, 1)
        end
    end))
end

--- Standard error wording for a failed page.fetch. Callers with bespoke
--- messages (e.g. solutions' session-expiry hint) build their own; an
--- HTTP-status error already carries the right wording and is passed on.
---@param what string e.g. "the leaderboard"
---@param perr cw.err the error page.fetch passed to the callback
---@return cw.err
function page.fetch_err(what, perr)
    if perr.status then
        return perr
    end
    return { msg = perr.curl and ("Failed to fetch %s (curl error)"):format(what)
        or ("Empty response when fetching %s."):format(what) }
end

--- Read the final response's status and Retry-After out of a curl `-D`
--- header dump. With -L the dump holds one block per hop; the last block
--- is the response whose body we have.
---@param dump string
---@return integer? status, string? retry_after
function page.parse_header_dump(dump)
    local status, retry_after
    for line in (dump or ""):gmatch("[^\r\n]+") do
        local code = line:match("^HTTP/[%d.]+%s+(%d%d%d)")
        if code then
            status, retry_after = tonumber(code), nil
        else
            -- Header names are case-insensitive; servers send Retry-After,
            -- retry-after and RETRY-AFTER alike.
            local name, v = line:match("^([%w%-]+):%s*(.-)%s*$")
            if name and name:lower() == "retry-after" then retry_after = v end
        end
    end
    return status, retry_after
end

--- Read a whole file, or "" when it does not exist.
---@param path string
---@return string
function page.slurp(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a")
    f:close()
    return s
end

--- vim.fn.jobstart that never leaves a caller hanging: returns the job id,
--- or nil when the job could not be started. jobstart returns 0 or -1 for
--- a bad command and RAISES (E475) when the executable is missing, and in
--- both cases on_exit never fires -- so every transport that waited for
--- on_exit alone spun forever with curl absent from PATH.
---@param cmd string[]
---@param opts table jobstart options
---@return integer? job id
function page.spawn(cmd, opts)
    local ok, id = pcall(vim.fn.jobstart, cmd, opts)
    if not ok or type(id) ~= "number" or id <= 0 then
        return nil
    end
    return id
end

--- Turn an HTTP status into the error shape api.utils produces, so callers
--- can branch on `auth` / `rate_limited` / `status` regardless of which
--- transport fetched the page. nil for a success.
---@param status integer?
---@param retry_after string?
---@return cw.err?
function page.status_err(status, retry_after)
    if not status or status < 300 then return nil end
    if status == 429 then
        return {
            status = 429, rate_limited = true,
            retry_after = tonumber(retry_after), retry_after_raw = retry_after,
            msg = "Codewars is rate limiting requests. Wait a minute and try again.",
        }
    end
    if status == 401 or status == 403 then
        return { status = status, auth = true, msg = "Session expired or invalid. Run :CW cookie to re-authenticate." }
    end
    return { status = status, msg = ("Codewars answered HTTP %d."):format(status) }
end

-- A rate-limited page is retried a few times with the API layer's backoff
-- (Retry-After honoured); anything else is reported once.
page.MAX_429_RETRIES = 2

--- Fetch a server-rendered HTML page into a temp file (preserves newlines
--- exactly, unlike jobstart stdout chunking) and return its body.
--- Errors carry flags so callers can word their own messages: `curl =
--- true` (transport failure), `empty = true` (blank body), or an HTTP
--- `status` with `auth` / `rate_limited` set. curl exits 0 on a 429 or a
--- 403, so without the status check the error page was handed to the HTML
--- parsers as if it were content and reported as "session expired" or
--- "markup changed".
---@param url string absolute URL
---@param cb fun(body: string?, err: cw.err?)
---@param attempt integer? 429 retries already made (internal)
function page.fetch(url, cb, attempt)
    attempt = attempt or 0
    local header_args = {}
    for k, v in pairs(headers_mod.get()) do
        table.insert(header_args, "-H")
        table.insert(header_args, k .. ": " .. v)
    end

    local tmp = vim.fn.tempname()
    local hdr = vim.fn.tempname()

    local cmd = vim.list_extend({
        "curl", "-s", "-L",
        -- Accept gzip: Codewars HTML compresses ~8x (a popular kata's
        -- solutions page is ~440 KB raw, ~57 KB compressed).
        "--compressed",
        "-o", tmp,
        "-D", hdr,
        url,
        "--max-time", "30",
    }, header_args)

    local slurp = page.slurp

    local job = page.spawn(cmd, {
        on_exit = vim.schedule_wrap(function(_, exit_code)
            local body, dump = slurp(tmp), slurp(hdr)
            pcall(os.remove, tmp)
            pcall(os.remove, hdr)

            if exit_code ~= 0 then
                return cb(nil, { msg = "Failed to fetch " .. url .. " (curl error)", curl = true })
            end

            local err = page.status_err(page.parse_header_dump(dump))
            if err then
                if err.rate_limited and attempt < page.MAX_429_RETRIES then
                    local wait = require("codewars.api.utils").retry_delay_ms(err, attempt)
                    return vim.defer_fn(function() page.fetch(url, cb, attempt + 1) end, wait)
                end
                return cb(nil, err)
            end
            if body == "" then
                return cb(nil, { msg = "Empty response from " .. url, empty = true })
            end
            cb(body)
        end),
    })

    -- The job never started (curl missing, spawn refused): on_exit will not
    -- run, so report it here or the caller's spinner spins forever.
    if not job then
        pcall(os.remove, tmp)
        pcall(os.remove, hdr)
        cb(nil, { msg = "Could not start curl to fetch " .. url .. ". Is curl installed?", curl = true })
    end
end

return page
