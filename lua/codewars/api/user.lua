local utils = require("codewars.api.utils")
local urls = require("codewars.api.urls")
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
--- Routed through api.utils rather than calling curl directly: this is the
--- ONLY place the username is ever discovered, so a single 429 here used to
--- leave the whole session without an identity. Going through the shared
--- layer means a rate-limited dashboard is retried instead of abandoned.
function user.get_current(cb)
    local hdrs = headers_mod.get()
    hdrs["Accept"] = "text/html"

    utils.get("/dashboard", {
        headers = hdrs,
        callback = function(res, err)
            if err then
                return cb(nil, err)
            end

            -- The dashboard is HTML, so handle_res hands back the raw body.
            local body = type(res) == "string" and res or ""

            -- Extract currentUser JSON from: currentUser = JSON.parse("{...}")
            local json_str = body:match('currentUser%s*=%s*JSON%.parse%("(.-)"%)')
            if not json_str then
                -- Either the markup drifted, or this is the login page
                -- because the cookie expired. Both leave us anonymous.
                return cb(nil, {
                    msg = "Could not read your profile from the Codewars dashboard. "
                        .. "Run :CW cookie if your session expired.",
                })
            end

            -- Unescape the JSON (it's double-escaped in the HTML)
            json_str = json_str:gsub('\\"', '"')
            json_str = json_str:gsub('\\\\', '\\')

            -- Shared null policy: a vim.NIL current_language would poison
            -- config.lang on first-run auto-detect.
            local ok, profile = utils.decode_json(json_str)
            if ok and profile then
                cb(profile)
            else
                cb(nil, { msg = "Failed to parse currentUser JSON" })
            end
        end,
    })
end

return user
