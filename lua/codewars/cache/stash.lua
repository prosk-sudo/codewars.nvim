local cache_utils = require("codewars.cache.utils")
local log = require("codewars.logger")
local HEX24 = require("codewars.api.utils").HEX24

--- On-disk stash for unsaved workspace edits. Kumite and kata both need one; only the filename prefix and the entry
--- shape differ, so the mechanism lives here once.
---
--- The contract that matters: save() returns a path ONLY when the bytes
--- actually reached disk. A caller that destroys buffers afterwards must be
--- able to tell "stashed" from "lost".
---@class cw.cache.Stash
local M = {}

--- An id becomes part of a file name and comes from unvalidated server replies
--- and scraped pages, so one holding "../" would write outside the cache dir.
--- Only two shapes are allowed, neither with a path separator: a Codewars id
--- (24 hex characters) and the "local-<ms>" id `:CW kumite new` gives a draft
--- until its first save, which a dirty close must still be able to stash.
---@param id any
---@return boolean
local function is_safe_id(id)
    if type(id) ~= "string" then
        return false
    end
    return id:match("^" .. HEX24 .. "$") ~= nil or id:match("^local%-%d+$") ~= nil
end

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
        -- Callers treat nil as "not stashed" and keep the buffers open.
        if not is_safe_id(entry.id) then
            -- Capped: the id is untrusted text on its way into a notification.
            local shown = vim.inspect(tostring(entry.id):sub(1, 40))
            log.warn(("Refusing to stash an entry with an unsafe id: %s"):format(shown))
            return nil
        end
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
        if not is_safe_id(id) then
            return nil
        end
        local path = file(id)
        if not path:exists() then
            return nil
        end
        return cache_utils.read_json(path)
    end

    ---@param id string
    ---@return boolean removed
    function kind.delete(id)
        if not is_safe_id(id) then
            return false
        end
        local path = file(id)
        if not path:exists() then
            return false
        end
        return pcall(path.rm, path)
    end

    return kind
end

return M
