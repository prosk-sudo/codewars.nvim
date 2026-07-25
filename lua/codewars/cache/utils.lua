local P = require("plenary.path")
local config = require("codewars.config")
local log = require("codewars.logger")

local M = {}

---@param name string filename within the cache directory
---@return Path
function M.cache_file(name)
    if config.storage.cache then
        return config.storage.cache:joinpath(name)
    end
    local dir = P:new(vim.fn.stdpath("cache") .. "/codewars")
    dir:mkdir({ parents = true })
    return dir:joinpath(name)
end

---@param path Path
---@return table?
function M.read_json(path)
    local ok, data = pcall(function()
        -- Mirrors api.utils.DECODE_OPTS (cache layer avoids that import)
        return vim.json.decode(path:read(), { luanil = { object = true } })
    end)
    return ok and data or nil
end

--- Write `data` as JSON. Returns whether it actually landed, so callers that
--- destroy the original afterwards (the stashes, on a dirty close) can tell
--- the difference between "saved" and "lost". Swallowing this made a failed
--- write look identical to a successful one.
---@param path Path
---@param data table
---@return boolean ok
---@return string? err
function M.write_json(path, data)
    local ok, err = pcall(function()
        path:write(vim.json.encode(data), "w")
    end)
    if not ok then
        log.error("Failed to write cache: " .. tostring(err))
        return false, tostring(err)
    end
    -- A write can report success and still leave nothing on disk (a full or
    -- read-only volume surfaces late); confirm before claiming it persisted.
    local checked, exists = pcall(function()
        return path:exists()
    end)
    if not checked or not exists then
        log.error("Cache write reported success but the file is missing: " .. tostring(path))
        return false, "file missing after write"
    end
    return true, nil
end

return M
