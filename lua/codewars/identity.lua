--- Who is signed in.
---
--- `config.user.username` is never configured by hand: it is detected, from
--- the identity cached for this session (cache.profile) or by reading it off
--- /dashboard. The menu does that when it opens, so a command run before the
--- menu finds it empty. The detection pieces live here so that anything else
--- that needs the account shares them.
---
--- Everything is required lazily: cookie.lua clears the profile cache from
--- identity_changed(), so a top-level require here would be a cycle.
---@class cw.Identity
local M = {}

--- Only when the user has not chosen one themselves. Auto-detection is never
--- persisted, so it is re-applied on every launch, which is why the cache
--- carries the language and not just the name.
---@param lang any
function M.apply_lang(lang)
    local config = require("codewars.config")
    if config.lang_persisted or type(lang) ~= "string" or lang == "" then
        return
    end
    config.lang = lang
    config.user.lang = lang
end

--- A reply may only write if the identity it was issued under is still the
--- current one.
---
--- profile.save() stamps a record with the cookie live when the reply LANDS,
--- while the request closed over the name it was ISSUED for. Without this,
--- signing into another account while a stats call is in flight would rebind
--- the old name to the new session's fingerprint. The name is checked too: a
--- rename healed mid-flight keeps the cookie, so the fingerprint alone would
--- miss it.
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

--- Take `username`, and the language the dashboard reports, as who is signed
--- in, and remember it for the next launch.
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

--- One /dashboard read: who this cookie belongs to. `on_reply(profile, err)`
--- is called unless the session changed while the request was out; then the
--- reply is dropped and `on_stale` is called instead, if given.
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

--- Make sure the account is known, then call `cb(username)`; or
--- `cb(nil, err)` when it cannot be: `err.signed_out` with no cookie saved,
--- `err.auth` when Codewars refuses the cookie (it expired), otherwise
--- whatever went wrong. Tries the known name, then this session's cached
--- identity (as the menu does), then the dashboard.
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
