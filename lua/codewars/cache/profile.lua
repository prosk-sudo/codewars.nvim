local cache_utils = require("codewars.cache.utils")

--- Who you are, remembered between launches.
---
--- Identity discovery costs a GET of /dashboard: ~112KB of session-rendered
--- HTML, scraped for one username, and by far the slowest thing on the menu's
--- path (measured 0.85s to 15.2s against a 0.3s API call). The name never
--- changes for a given session, so paying that on every launch buys nothing.
---
--- Caching an identity is only safe when it cannot outlive the session that
--- produced it. Commit ccb634e removed the configurable `username` because a
--- name that disagreed with the cookie showed one account's stats while acting
--- as another; a cached name is the same hazard from a file instead of a
--- config line. Hence the fingerprint: every read is bound to the live cookie,
--- and a session it does not match reads as absent.
---@class cw.Cache.Profile
local M = {}

---@return Path
local function file()
    return cache_utils.cache_file("profile.json")
end

-- Codewars usernames are word characters plus `-`, `_` and `.`. The cap is a
-- sanity bound, not a rule of theirs.
local USERNAME_MAX = 64

--- The value is interpolated into `/api/v1/users/%s` and keys the completed
--- cache, and it arrives off disk, so it is checked on the way in and out
--- rather than trusted.
---@param name any
---@return boolean
function M.valid_username(name)
    return type(name) == "string"
        and #name > 0
        and #name <= USERNAME_MAX
        and name:match("^[%w_%-%.]+$") ~= nil
end

--- Identifies the session without copying it. A hash, never the token: there
--- is no reason to duplicate a live credential into a second file, and the
--- only question ever asked of it is "same session as before?".
---
--- Required lazily. cookie.lua clears this module from identity_changed(),
--- so a top-level require here would be a cycle.
---@return string? nil when signed out
function M.fingerprint()
    local ok, cookie = pcall(require, "codewars.cache.cookie")
    if not ok then
        return nil
    end
    local c = cookie.get()
    if not c or type(c.session_id) ~= "string" or c.session_id == "" then
        return nil
    end
    return vim.fn.sha256(c.session_id)
end

---@class cw.cache.ProfileData
---@field username string
---@field lang string?
---@field honor integer?
---@field rank_name string?
---@field completed integer?

--- The cached identity, or nil when there is none for THIS session.
---@return cw.cache.ProfileData?
function M.get()
    local fp = M.fingerprint()
    if not fp then
        return nil
    end

    local raw = cache_utils.read_json(file())
    if type(raw) ~= "table" or raw.fingerprint ~= fp then
        return nil
    end
    if not M.valid_username(raw.username) then
        return nil
    end

    return {
        username = raw.username,
        lang = raw.lang,
        honor = raw.honor,
        rank_name = raw.rank_name,
        completed = raw.completed,
    }
end

--- Persist an identity discovered from the dashboard.
---
--- Only ever called with server-sourced values. Menu.refresh_stats bumps the
--- completed count optimistically before refetching; persisting that would
--- bake a wrong number into the cache when the refetch fails.
---@param data cw.cache.ProfileData
---@return boolean ok
function M.save(data)
    local fp = M.fingerprint()
    if not fp then
        return false
    end
    if not M.valid_username(data and data.username) then
        return false
    end

    return (cache_utils.write_json(file(), {
        fingerprint = fp,
        username = data.username,
        lang = data.lang,
        honor = data.honor,
        rank_name = data.rank_name,
        completed = data.completed,
    }))
end

--- Merge `fields` into the stored record.
---
--- The record is filled from two responses that each know half of it:
--- /dashboard supplies the username and language, /api/v1/users the stats.
--- Whichever lands second would blank the other half with a plain save.
---@param fields cw.cache.ProfileData
---@return boolean ok
function M.update(fields)
    local merged = vim.tbl_extend("force", M.get() or {}, fields or {})
    return M.save(merged)
end

--- Belt to the fingerprint's braces. The fingerprint alone already refuses a
--- profile from another session, but a sign-out should not leave the previous
--- account's name sitting on disk either.
---@return boolean removed
function M.clear()
    local f = file()
    local ok, exists = pcall(function() return f:exists() end)
    if not ok or not exists then
        return false
    end
    return (pcall(f.rm, f))
end

return M
