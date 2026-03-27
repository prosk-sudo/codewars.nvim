local log = require("codewars.logger")
local cache_utils = require("codewars.cache.utils")

local cached_cookie = nil

---@class cw.cache.Cookie
---@field csrf_token string
---@field session_id string
---@field str string

---@class cw.Cookie
local Cookie = {}

---@return Path
local function file()
    return cache_utils.cache_file("cookie")
end

---@param str string
---@return string? error
function Cookie.set(str)
    local _, cerr = Cookie.parse(str)
    if cerr then
        return cerr
    end

    file():write(str, "w")
    cached_cookie = nil
    log.info("Cookie saved successfully")
    return nil
end

---@return boolean
function Cookie.delete()
    cached_cookie = nil
    local f = file()
    if not f:exists() then
        return false
    end
    return pcall(f.rm, f)
end

---@return cw.cache.Cookie?
function Cookie.get()
    if cached_cookie then
        return cached_cookie
    end

    local f = file()
    if not f:exists() then
        return
    end

    local contents = f:read()
    if not contents or type(contents) ~= "string" then
        return
    end

    contents = select(1, contents:gsub("^%s*(.-)%s*$", "%1"))
    local cookie = Cookie.parse(contents)
    if cookie then
        cached_cookie = cookie
    end
    return cookie
end

---@param str string
---@return cw.cache.Cookie?, string?
function Cookie.parse(str)
    local csrf = str:match("CSRF%-TOKEN=([^;]+)")
    if not csrf or csrf == "" then
        csrf = str:match("csrf%-token=([^;]+)")
    end
    if not csrf or csrf == "" then
        return nil, "Bad CSRF-TOKEN format. Expected: CSRF-TOKEN=...; _session_id=...;"
    end

    local session = str:match("_session_id=([^;]+)")
    if not session or session == "" then
        return nil, "Bad _session_id format. Expected: CSRF-TOKEN=...; _session_id=...;"
    end

    return { csrf_token = csrf, session_id = session, str = str }
end

return Cookie
