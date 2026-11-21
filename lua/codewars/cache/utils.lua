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

-- What has been reported, so that each is said once: a file whose backup could
-- not be written back (each read of it would say it again), and a note from a write.
local reported = {}

---@param key string
---@param message string
local function warn_once(key, message)
    if reported[key] then return end
    reported[key] = true
    log.warn(message)
end

--- `file` is absent, or was read in full and is damaged. A good copy at its
--- backup's name is written back into it and returned; the backup stays where
--- it is (only a writer removes one).
---@param file string
---@param main_stat table? the descriptor's stat when `file` was read
---@return table? data the backup's, when it was recovered
local function recover(file, main_stat)
    if not backup.has_backup(file) then return nil end
    local recovered, err = backup.settle(file, parse, main_stat)
    if recovered == nil then return nil end
    if not err then
        reported[file] = nil
        log.warn(("Recovered %s from its backup: the last write to it did not finish."):format(file))
    else
        warn_once(file, ("Recovered %s from %s, but could not write it back (%s); the backup is kept."):format(
            file, backup.backup_path(file), err))
    end
    return recovered
end

---@param path Path
---@return table?
function M.read_json(path)
    local file = backup.file_name(path)
    local state, detail, stat = backup.read_main(file)
    -- Could not be read: not known to be damaged, so not recovered over.
    if state == "unreadable" then return nil end
    local data = state == "read" and parse(detail) or nil
    if data ~= nil then return data end
    -- Absent, or read in full and empty or undecodable.
    return recover(file, stat)
end

--- Write `data` as JSON. Returns whether it actually landed, so callers that
--- destroy the original afterwards (the stashes, on a dirty close) can tell
--- the difference between "saved" and "lost". Swallowing this made a failed
--- write look identical to a successful one.
---
--- A write that fails partway keeps the previous cache (see cache.backup): the
--- file is rewritten in place, never replaced, so it keeps its owner, mode and
--- read-only state, and what was there is put back on a failure. A cache that
--- cannot be backed up first is not written at all, and that is reported.
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

    local ok, err, note = backup.write(backup.file_name(path), text, parse)
    if note and not quiet then warn_once(note, note) end
    if not ok then return fail(err) end
    return true, nil
end

return M
