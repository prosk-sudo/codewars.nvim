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

-- What was already reported, so a warning is not repeated (a failed write-back would repeat on every read).
local reported = {}

---@param key string
---@param message string
local function warn_once(key, message)
    if reported[key] then return end
    reported[key] = true
    log.warn(message)
end

--- `file` was read in full and is empty or undecodable: write a good backup back into it and return its data.
--- The backup stays: a reader never removes one, as a writer may be between making it and rewriting the cache.
---@param file string
---@param main_stat table the descriptor's stat when `file` was read
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
    -- Unreadable is not known to be damaged, and absent was deleted: neither is recovered.
    if state ~= "read" then return nil end
    local data = parse(detail)
    if data ~= nil then return data end
    -- Present and undecodable: damaged, as an interrupted write leaves it.
    return recover(file, stat)
end

--- Write `data` as JSON. Returns whether it actually landed, so callers that
--- destroy the original afterwards (the stashes, on a dirty close) can tell
--- the difference between "saved" and "lost". Swallowing this made a failed
--- write look identical to a successful one.
---
--- A failed write keeps the previous cache (see cache.backup): put back in place, or left in the backup if that fails.
--- A cache that cannot be backed up first is not written, and that is reported.
---@param path Path
---@param data table
---@param opts { quiet: boolean? }? `quiet`: log nothing on failure, for a caller that reports it itself
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
