local cache_utils = require("codewars.cache.utils")

--- On-disk stash for unsaved workspace edits (design §3.6 / eng D10 safety
--- net). Kumite and kata both need one; only the filename prefix and the entry
--- shape differ, so the mechanism lives here once.
---
--- The contract that matters: save() returns a path ONLY when the bytes
--- actually reached disk. A caller that destroys buffers afterwards must be
--- able to tell "stashed" from "lost".
---@class cw.cache.Stash
local M = {}

---@param prefix string filename prefix, e.g. "kumite-stash-"
---@return table
function M.for_kind(prefix)
    local kind = {}

    local function file(id)
        return cache_utils.cache_file(prefix .. id .. ".json")
    end

    --- Persist an entry, stamping saved_at in UTC.
    ---@param entry table must carry `id`
    ---@return string? path absolute path written, nil when nothing landed
    function kind.save(entry)
        entry.saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        local path = file(entry.id)
        local ok = cache_utils.write_json(path, entry)
        if not ok then
            return nil
        end
        return path:absolute()
    end

    ---@param id string
    ---@return table?
    function kind.get(id)
        local path = file(id)
        if not path:exists() then
            return nil
        end
        return cache_utils.read_json(path)
    end

    ---@param id string
    ---@return boolean removed
    function kind.delete(id)
        local path = file(id)
        if not path:exists() then
            return false
        end
        return pcall(path.rm, path)
    end

    return kind
end

return M
