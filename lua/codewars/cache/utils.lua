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

--- Write all of `text` to `fd`, from the start. A write that makes no
--- progress (0 bytes, or an error) is a failure: stopping quietly at a short
--- count is how half a file gets called saved.
---@param fd integer
---@param text string
---@return boolean ok
---@return string? err
local function write_all(fd, text)
    local uv = vim.uv or vim.loop
    local written = 0
    while written < #text do
        local count, err = uv.fs_write(fd, text:sub(written + 1), written)
        if not count then return false, tostring(err) end
        if count <= 0 then return false, "wrote no bytes (the disk may be full)" end
        written = written + count
    end
    return true
end

--- Write `data` as JSON, whole or not at all. Returns whether it actually
--- landed, so callers that destroy the original afterwards (the stashes, on a
--- dirty close) can tell the difference between "saved" and "lost". Swallowing
--- this made a failed write look identical to a successful one.
---
--- The file is replaced, never written in place: opening it to write
--- truncates it first, so a disk that fills halfway left an empty or partial
--- cache where a good one had been. The JSON goes to a temp file beside it,
--- exclusively created, is written in full and closed, and only then renamed
--- over the destination. On any failure the temp file is removed and the
--- destination is as it was. The file keeps the mode it had (a new one gets
--- the default); a symlink is written through, to the file it points at.
---@param path Path
---@param data table
---@param opts { quiet: boolean? }? `quiet`: log nothing on failure, for a caller that reports it itself in its own words (and may try again, as a batch of lookups does, without a line per try)
---@return boolean ok
---@return string? err
function M.write_json(path, data, opts)
    local quiet = opts and opts.quiet
    local uv = vim.uv or vim.loop

    local function fail(err)
        if not quiet then log.error("Failed to write cache: " .. tostring(err)) end
        return false, tostring(err)
    end

    local encoded_ok, encoded = pcall(vim.json.encode, data)
    if not encoded_ok then return fail("could not encode the data: " .. tostring(encoded)) end

    local dest = type(path) == "string" and path or path:absolute()
    -- Beside the file that is really there, so the rename stays on one volume.
    dest = uv.fs_realpath(dest) or dest
    local existing = uv.fs_stat(dest)
    local mode = existing and bit.band(existing.mode, tonumber("777", 8)) or 438
    local temp = ("%s.tmp.%d.%d"):format(dest, uv.os_getpid(), uv.hrtime())

    local fd, open_err = uv.fs_open(temp, "wx", mode)
    if not fd then return fail(open_err) end

    -- fs_open's mode is masked by the umask a second time, which would strip
    -- bits the file already had (a group-writable cache refreshed under
    -- umask 022 came back 0644). Set the exact mode instead -- but only on a
    -- replacement: a new file gets the default, umask and all.
    local written, write_err = true, nil
    if existing then
        local set, chmod_err = uv.fs_fchmod(fd, mode)
        if not set then written, write_err = false, tostring(chmod_err or "could not set the file's mode") end
    end
    -- The new inode is owned by whoever made it, and a cache shared through
    -- a project group would leave that group. So hand it back to the file's
    -- owner and group -- best effort: an unprivileged user usually cannot
    -- give a file away, and the caches in one's own cache directory have
    -- nobody to give them to, so a refusal is not a failed write.
    if written and existing then uv.fs_fchown(fd, existing.uid, existing.gid) end
    if written then written, write_err = write_all(fd, encoded) end
    local closed, close_err = uv.fs_close(fd)
    if written and not closed then written, write_err = false, tostring(close_err) end
    if not written then
        uv.fs_unlink(temp)
        return fail(write_err)
    end

    local renamed, rename_err = uv.fs_rename(temp, dest)
    if not renamed then
        uv.fs_unlink(temp)
        return fail(rename_err)
    end
    return true, nil
end

return M
