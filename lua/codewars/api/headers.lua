local log = require("codewars.logger")

---@class cw.Api.Headers
local headers = {}

---@return table
function headers.get()
    local cookie = require("codewars.cache.cookie")
    local c = cookie.get()

    if not c then
        log.debug("No cookie found, sending unauthenticated request")
        return {
            ["Content-Type"] = "application/json",
        }
    end

    -- URL-decode the CSRF token for the header
    local csrf_decoded = c.csrf_token
    pcall(function()
        csrf_decoded = vim.uri_decode(c.csrf_token)
    end)

    return {
        ["Content-Type"] = "application/json",
        ["X-Csrf-Token"] = csrf_decoded,
        ["Cookie"] = ("CSRF-TOKEN=%s; _session_id=%s"):format(c.csrf_token, c.session_id),
        ["User-Agent"] = "Mozilla/5.0 (compatible; codewars.nvim)",
    }
end

return headers
