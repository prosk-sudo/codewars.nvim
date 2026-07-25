local cache_utils = require("codewars.cache.utils")

--- Local stash for unsaved kumite edits (design §3.6 / eng D10 safety net).
--- On a dirty-close the workspace writes one JSON file per snippet, so edits
--- that were never sent to codewars.com survive the close. Nothing reads them
--- back yet — the My Drafts picker will; until then they are a durable
--- on-disk backstop you can recover by hand.
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
