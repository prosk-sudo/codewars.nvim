local cache_utils = require("codewars.cache.utils")

---@class cw.Cache.Session
local session = {}

local dir_created = false

---@param slug string
---@param lang string
---@return Path
local function session_file(slug, lang)
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
    local data = cache_utils.read_json(session_file(slug, lang))
    if not data then return nil end
    local age = os.time() - (data.cached_at or 0)
    if age > SESSION_TTL then return nil end
    return data
end

---@param slug string
---@param lang string
---@param data table
function session.save(slug, lang, data)
    data.cached_at = os.time()
    cache_utils.write_json(session_file(slug, lang), data)
end

---@param slug string
---@param lang string
function session.delete(slug, lang)
    local f = session_file(slug, lang)
    if f:exists() then
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
