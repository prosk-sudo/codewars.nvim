--- Who is signed in. `config.user.username` is detected (cached identity or /dashboard),
--- never configured; the pieces are shared so commands run before the menu can use them.
--- Required lazily: cookie.lua clears the profile cache from identity_changed() (a cycle).
---@class cw.Identity
local M = {}

--- Only if the user chose no language. Detection is never persisted, so this runs
--- every launch and the cache carries the language.
---@param lang any
function M.apply_lang(lang)
    local config = require("codewars.config")
    if config.lang_persisted or type(lang) ~= "string" or lang == "" then
        return
    end
    config.lang = lang
    config.user.lang = lang
end

--- A reply may write only if its identity is still current: profile.save() stamps the
--- cookie live when the reply LANDS, so a mid-flight account switch would rebind the old
--- name to the new session. The name is checked too: a mid-flight rename keeps the cookie.
---@param name string? the username the request was issued for
---@return fun(): boolean
function M.still_current(name)
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local profile_cache = require("codewars.cache.profile")
    local at_issue = profile_cache.fingerprint()
    return function()
        if profile_cache.fingerprint() ~= at_issue then
            log.debug("dropping a reply from a previous session")
            return false
        end
        if name and config.user.username ~= name then
            log.debug("dropping a reply for a name that is no longer ours")
            return false
        end
        return true
    end
end

--- Take `username` and the dashboard's language as who is signed in, and remember it.
---@param username string
---@param lang string?
function M.adopt(username, lang)
    local config = require("codewars.config")
    config.user.username = username
    M.apply_lang(lang)
    require("codewars.cache.profile").update({
        username = username,
        lang = lang,
    })
end

--- One /dashboard read. `on_reply(profile, err)` is skipped if the session changed
--- mid-request; `on_stale` is called instead, if given.
---@param on_reply fun(profile: table?, err: table?)
---@param on_stale fun()?
function M.scrape(on_reply, on_stale)
    local ours = M.still_current()
    require("codewars.api.user").get_current(function(profile, err)
        if not ours() then
            if on_stale then on_stale() end
            return
        end
        on_reply(profile, err)
    end)
end

--- Make sure the account is known, then `cb(username)`; or `cb(nil, err)` with
--- `err.signed_out` (no cookie), `err.auth` (cookie refused) or whatever failed.
---@param cb fun(username: string?, err: table?)
function M.ensure(cb)
    local config = require("codewars.config")
    if config.user.username ~= "" then
        return cb(config.user.username)
    end
    if not require("codewars.cache.cookie").get() then
        return cb(nil, { signed_out = true, msg = "not signed in" })
    end

    local cached = require("codewars.cache.profile").get()
    if cached then
        config.user.username = cached.username
        M.apply_lang(cached.lang)
        return cb(cached.username)
    end

    M.scrape(function(profile, err)
        if err or not profile or not profile.username then
            return cb(nil, err or { msg = "the dashboard did not say who you are" })
        end
        M.adopt(profile.username, profile.current_language)
        cb(profile.username)
    end, function()
        cb(nil, { msg = "your session changed while your username was being detected" })
    end)
end

return M
