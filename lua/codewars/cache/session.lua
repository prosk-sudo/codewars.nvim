local cache_utils = require("codewars.cache.utils")
local backup = require("codewars.cache.backup")

-- vim.uv arrived in 0.10; the plugin still supports 0.9.
local uv = vim.uv or vim.loop

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
    backup.drop(f)
    if f:exists() then
        f:rm()
    end
end

---@param dir Path
---@return string[] names every entry of the sessions directory
local function entries(dir)
    local names = {}
    local scan = uv.fs_scandir(dir:absolute())
    while scan do
        local name = uv.fs_scandir_next(scan)
        if not name then break end
        names[#names + 1] = name
    end
    return names
end

--- Number of cached sessions. A session's backup is not another one.
---@return integer
function session.count()
    local dir = cache_utils.cache_file("sessions")
    if not dir:exists() then return 0 end

    local count = 0
    for _, name in ipairs(entries(dir)) do
        if name:match("%.json$") then count = count + 1 end
    end
    return count
end

--- Delete all cached sessions, and their backups: one left behind would bring
--- its session back on the next read. Returns how many sessions were deleted;
--- a backup is not counted.
---@return integer
function session.clear_all()
    local dir = cache_utils.cache_file("sessions")
    if not dir:exists() then return 0 end

    local count = 0
    for _, name in ipairs(entries(dir)) do
        local f = dir:joinpath(name)
        if name:match("%.json$") then
            if pcall(f.rm, f) then count = count + 1 end
        elseif backup.is_backup(name) then
            pcall(f.rm, f)
        end
    end
    return count
end

return session
