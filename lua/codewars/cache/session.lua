local cache_utils = require("codewars.cache.utils")
local log = require("codewars.logger")
local safe_name = require("codewars.safe_name")

---@class cw.Cache.Session
local session = {}

local dir_created = false

--- The cache file for a kata and language, or nil when either is not a plain name.
--- Both come from a Codewars reply, so `../x` would otherwise write outside the sessions directory.
---@param slug string
---@param lang string
---@return Path?
local function session_file(slug, lang)
    if not (safe_name.is_slug(slug) and safe_name.is_slug(lang)) then
        return nil
    end
    local dir = cache_utils.cache_file("sessions")
    if not dir_created then
        dir:mkdir({ parents = true })
        dir_created = true
    end
    return dir:joinpath(slug .. "_" .. lang .. ".json")
end

local SESSION_TTL = 60 * 60 * 24 * 7 -- 7 days

---@param slug string
---@param lang string
---@return table?
function session.get(slug, lang)
    local file = session_file(slug, lang)
    if not file then return nil end
    local data = cache_utils.read_json(file)
    if not data then return nil end
    local age = os.time() - (data.cached_at or 0)
    if age > SESSION_TTL then return nil end
    return data
end

---@param slug string
---@param lang string
---@param data table
function session.save(slug, lang, data)
    local file = session_file(slug, lang)
    if not file then
        log.warn(("Session not cached: %s and %s cannot name a cache file."):format(vim.inspect(slug), vim.inspect(lang)))
        return
    end
    data.cached_at = os.time()
    cache_utils.write_json(file, data)
end

---@param slug string
---@param lang string
function session.delete(slug, lang)
    local f = session_file(slug, lang)
    if f and f:exists() then
        f:rm()
    end
end

--- Delete all cached sessions.
function session.clear_all()
    local dir = cache_utils.cache_file("sessions")
    if not dir:exists() then return 0 end

    local count = 0
    local scan = vim.loop.fs_scandir(dir:absolute())
    if scan then
        while true do
            local name = vim.loop.fs_scandir_next(scan)
            if not name then break end
            if name:match("%.json$") then
                local f = dir:joinpath(name)
                local ok = pcall(f.rm, f)
                if ok then count = count + 1 end
            end
        end
    end
    return count
end

return session
