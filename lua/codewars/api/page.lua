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
    return (s:gsub("&[#%w]+;", ENTITIES))
end

--- Standard error wording for a failed page.fetch. Callers with bespoke
--- messages (e.g. solutions' session-expiry hint) build their own.
---@param what string e.g. "the leaderboard"
---@param perr cw.err the error page.fetch passed to the callback
---@return cw.err
function page.fetch_err(what, perr)
    return { msg = perr.curl and ("Failed to fetch %s (curl error)"):format(what)
        or ("Empty response when fetching %s."):format(what) }
end

--- Fetch a server-rendered HTML page into a temp file (preserves newlines
--- exactly, unlike jobstart stdout chunking) and return its body.
--- Errors carry a flag so callers can word their own messages:
--- `curl = true` (transport failure) or `empty = true` (blank body).
---@param url string absolute URL
---@param cb fun(body: string?, err: cw.err?)
function page.fetch(url, cb)
    local header_args = {}
    for k, v in pairs(headers_mod.get()) do
        table.insert(header_args, "-H")
        table.insert(header_args, k .. ": " .. v)
    end

    local tmp = vim.fn.tempname()

    local cmd = vim.list_extend({
        "curl", "-s", "-L",
        "-o", tmp,
        url,
        "--max-time", "15",
    }, header_args)

    vim.fn.jobstart(cmd, {
        on_exit = vim.schedule_wrap(function(_, exit_code)
            local body = ""
            local f = io.open(tmp, "r")
            if f then
                body = f:read("*a")
                f:close()
            end
            pcall(os.remove, tmp)

            if exit_code ~= 0 then
                return cb(nil, { msg = "Failed to fetch " .. url .. " (curl error)", curl = true })
            end
            if body == "" then
                return cb(nil, { msg = "Empty response from " .. url, empty = true })
            end
            cb(body)
        end),
    })
end

return page
