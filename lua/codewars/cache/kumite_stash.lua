local cache_utils = require("codewars.cache.utils")

--- Local stash for unsaved kumite edits (design §3.6 / eng D10 safety net).
--- On a dirty-close the workspace writes one JSON file per snippet so work
--- is never lost before P3's Save Draft exists. The My Drafts picker (P3)
--- will read these back; for now they are a durable on-disk backstop.
---@class cw.cache.KumiteStash
local M = {}

---@param id string snippet id (the stash key)
---@return Path
local function file(id)
    return cache_utils.cache_file("kumite-stash-" .. id .. ".json")
end

---@class cw.KumiteStashEntry
---@field id string
---@field title string
---@field language string
---@field parent_id string?
---@field code string
---@field fixture string
---@field saved_at string ISO 8601 UTC

--- Persist a stash entry. Stamps saved_at server-neutrally (UTC).
---@param entry cw.KumiteStashEntry
---@return string? path absolute path written, nil on failure
function M.save(entry)
    entry.saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local path = file(entry.id)
    cache_utils.write_json(path, entry)
    return path:absolute()
end

---@param id string
---@return cw.KumiteStashEntry?
function M.get(id)
    local path = file(id)
    if not path:exists() then
        return nil
    end
    return cache_utils.read_json(path)
end

---@param id string
---@return boolean removed
function M.delete(id)
    local path = file(id)
    if not path:exists() then
        return false
    end
    return pcall(path.rm, path)
end

return M
