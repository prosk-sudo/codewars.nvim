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
    Cookie.identity_changed()
    log.info("Cookie saved successfully")
    return nil
end

--- Drop EVERYTHING that belongs to the signed-in identity. Called when the
--- cookie is set or deleted. The review traced what survived an account
--- switch when only the solutions cache was dropped: Bob's :CW attempt
--- ran against Alice's cached project/solution ids, the picker marked
--- Alice's completed kata as Bob's (and the trainer dequeued them), the
--- menu kept saying "Signed in as: alice", and :CW focus skip acted on
--- Alice's remembered kata. Each of those lives in a different module, so
--- this is the one place that enumerates them.
---
--- Every hook is a pcall'd lazy require: the cookie module must not pull
--- the UI/picker chain in at load time, and a module that fails to load
--- must not stop the others from being cleared.
function Cookie.identity_changed()
    local function with(mod, fn)
        local ok, m = pcall(require, mod)
        if ok and m then pcall(fn, m) end
    end

    -- The user's own votes are baked into the cached solutions pages.
    with("codewars.api.solutions", function(m) m.invalidate() end)
    -- completed.json / kata_details.json are keyed by the old username.
    with("codewars.cache.completed", function(m) m.clear() end)
    -- sessions/*.json hold the old account's project/solution ids.
    with("codewars.cache.session", function(m) m.clear_all() end)
    -- The picker memoises the completed set in memory.
    with("codewars.picker", function(m) m.invalidate_completed_cache() end)
    -- The remembered focus kata belongs to the old account's queue.
    with("codewars.command", function(m) m.forget_focus() end)
    -- Detected from the old dashboard; the menu re-detects when empty.
    with("codewars.config", function(m) m.user.username = "" end)
end

---@return boolean
function Cookie.delete()
    cached_cookie = nil
    Cookie.identity_changed()
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
