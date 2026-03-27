local utils = require("codewars.api.utils")
local urls = require("codewars.api.urls")
local curl = require("plenary.curl")
local headers_mod = require("codewars.api.headers")

---@class cw.Api.User
local user = {}

---@param username string
---@param cb? function
---@return table?, cw.err?
function user.get(username, cb)
    local endpoint = urls.user:format(username)

    if cb then
        utils.get(endpoint, { callback = cb })
    else
        return utils.get(endpoint)
    end
end

--- Fetch the current logged-in user's profile from the dashboard page.
--- Parses currentUser JSON from the App.setup() JavaScript.
---@param cb function callback(profile?, err?)
function user.get_current(cb)
    local url = urls.base .. "/dashboard"
    local hdrs = headers_mod.get()

    curl.get(url, {
        headers = hdrs,
        compressed = false,
        callback = vim.schedule_wrap(function(out)
            if out.exit ~= 0 or out.status >= 300 then
                return cb(nil, { msg = "Failed to fetch dashboard" })
            end

            local body = out.body or ""

            -- Extract currentUser JSON from: currentUser = JSON.parse("{...}")
            local json_str = body:match('currentUser%s*=%s*JSON%.parse%("(.-)"%)')
            if not json_str then
                return cb(nil, { msg = "Could not find currentUser in dashboard" })
            end

            -- Unescape the JSON (it's double-escaped in the HTML)
            json_str = json_str:gsub('\\"', '"')
            json_str = json_str:gsub('\\\\', '\\')

            local ok, profile = pcall(vim.json.decode, json_str)
            if ok and profile then
                cb(profile)
            else
                cb(nil, { msg = "Failed to parse currentUser JSON" })
            end
        end),
    })
end

return user
