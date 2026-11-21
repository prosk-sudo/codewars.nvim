local P = require("plenary.path")
local config = require("codewars.config")
local log = require("codewars.logger")
local backup = require("codewars.cache.backup")

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

--- Mirrors api.utils.DECODE_OPTS (the cache layer avoids that import).
---@param text string
---@return table? data nil when `text` is not JSON
local function parse(text)
    local ok, data = pcall(vim.json.decode, text, { luanil = { object = true } })
    return ok and data or nil
end

-- Files whose backup could not be written back, already reported: each read
-- of one would otherwise say it again.
local reported = {}

--- A backup beside `file` means a write to it did not finish. Use it when the
--- file is not usable, and clear it away when the file is fine.
---@param path Path
---@param data table? what `path` holds, nil when missing or not JSON
---@return table? data the same, or the backup's when that was recovered
local function settle(path, data)
    local file = backup.file_name(path)
    local recovered, err = backup.settle(file, data ~= nil, parse)
    if recovered == nil then return data end
    if not err then
        reported[file] = nil
        log.warn(("Recovered %s from its backup: the last write to it did not finish."):format(file))
    elseif not reported[file] then
        reported[file] = true
        log.warn(("Recovered %s from %s, but could not write it back (%s); the backup is kept."):format(
            file, backup.backup_path(file), err))
    end
    return recovered
end

---@param path Path
---@return table?
function M.read_json(path)
    local read, text = pcall(function() return path:read() end)
    local data = read and parse(text) or nil
    if not backup.has_backup(backup.file_name(path)) then return data end
    return settle(path, data)
end

--- Write `data` as JSON. Returns whether it actually landed, so callers that
--- destroy the original afterwards (the stashes, on a dirty close) can tell
--- the difference between "saved" and "lost". Swallowing this made a failed
--- write look identical to a successful one.
---
--- A write that fails partway keeps the previous cache (see cache.backup): the
--- file is rewritten in place, never replaced, so it keeps its owner, mode and
--- read-only state, and what was there is put back on a failure.
---@param path Path
---@param data table
---@param opts { quiet: boolean? }? `quiet`: log nothing on failure, for a caller that reports it itself in its own words (and may try again, as a batch of lookups does, without a line per try)
---@return boolean ok
---@return string? err
function M.write_json(path, data, opts)
    local quiet = opts and opts.quiet
    local function fail(err)
        if not quiet then log.error("Failed to write cache: " .. tostring(err)) end
        return false, tostring(err)
    end

    local encoded, text = pcall(vim.json.encode, data)
    if not encoded then return fail(text) end

    local file = backup.file_name(path)
    -- A backup left by an earlier write that failed is settled first: if the
    -- file is damaged, the backup is the good copy, and must not be backed up over.
    if backup.has_backup(file) then M.read_json(path) end

    local ok, err = backup.write(file, text)
    if not ok then return fail(err) end
    return true, nil
end

return M
