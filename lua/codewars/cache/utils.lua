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

--- Give `fd`, the file about to replace `existing`, the owner and group
--- `existing` has -- a new inode belongs to whoever made it, and a cache
--- shared through a project group would leave that group -- and say whether
--- it has them. In order: both; failing that just the group, which a user may
--- set to any group they are in; then ask the file what it really has, since
--- an unprivileged user often cannot give a file away and neither call says
--- more than "no". When the user already owns it with the right group, the
--- first call changes nothing and succeeds, and this is the whole of it.
---@param fd integer
---@param existing table the stat of the file being replaced
---@return boolean kept
local function keep_owner(fd, existing)
    local uv = vim.uv or vim.loop
    if not uv.fs_fchown(fd, existing.uid, existing.gid) then
        local uid = uv.getuid and uv.getuid()
        if uid then uv.fs_fchown(fd, uid, existing.gid) end
    end
    local now = uv.fs_fstat(fd)
    return now ~= nil and now.uid == existing.uid and now.gid == existing.gid
end

--- Write `text` over the file at `dest` itself, truncating it first. The file
--- keeps its inode, so its owner and group, and a write that fails halfway
--- leaves it damaged: the price of keeping the owner when it cannot be given
--- back to a replacement.
---@param dest string
---@param text string
---@param full_mode integer? the file's mode, special bits included, to put back
---@return boolean ok
---@return string? err
local function write_in_place(dest, text, full_mode)
    local uv = vim.uv or vim.loop
    local fd, open_err = uv.fs_open(dest, "w", 438)
    if not fd then return false, tostring(open_err) end
    local ok, err = write_all(fd, text)
    -- Writing a file can clear its setuid and setgid bits for an ordinary user.
    if ok and full_mode then uv.fs_fchmod(fd, full_mode) end
    local closed, close_err = uv.fs_close(fd)
    if ok and not closed then ok, err = false, tostring(close_err) end
    return ok, err
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
--- the default); a symlink is written through, to the file it points at. Its
--- owner and group are kept too, when they can be (keep_owner). When they
--- cannot be given to a replacement, the file is written in place instead,
--- keeping its inode and so its owner and group, but no longer atomic: the
--- same trade Vim makes with backupcopy=auto. The user's own cache, the
--- common case, never gets there.
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
    -- The permission bits to create it with, and the whole mode (setuid,
    -- setgid and sticky bits too) to give it once it exists.
    local perms = existing and bit.band(existing.mode, tonumber("777", 8)) or 438
    local full_mode = existing and bit.band(existing.mode, tonumber("7777", 8))
    local temp = ("%s.tmp.%d.%d"):format(dest, uv.os_getpid(), uv.hrtime())

    local fd, open_err = uv.fs_open(temp, "wx", perms)
    if not fd then
        -- Nothing can be created beside the file (a directory one may not
        -- write to, say). The file itself may still be writable, so write
        -- that, as Vim does; a new file has nothing to write in place.
        if not existing then return fail(open_err) end
        local in_place, place_err = write_in_place(dest, encoded, full_mode)
        if not in_place then return fail(place_err) end
        return true, nil
    end

    -- Ownership first, and only on a replacement: a new file belongs to whoever
    -- made it. It is kept if it can be (keep_owner); if not, this inode would
    -- be the wrong owner, so it is abandoned and the file written in place.
    -- Before the bytes and the mode, because changing the owner clears setuid
    -- and setgid.
    if existing and not keep_owner(fd, existing) then
        uv.fs_close(fd)
        uv.fs_unlink(temp)
        local in_place, place_err = write_in_place(dest, encoded, full_mode)
        if not in_place then return fail(place_err) end
        return true, nil
    end

    -- The bytes go in first: writing a file can clear its setuid and setgid
    -- bits for an ordinary user, so the mode is set after them.
    local written, write_err = write_all(fd, encoded)

    -- fs_open's mode is masked by the umask a second time, which would strip
    -- bits the file already had (a group-writable cache refreshed under
    -- umask 022 came back 0644). Set the exact mode instead -- but only on a
    -- replacement: a new file gets the default, umask and all. The special
    -- bits go with it; the system may refuse them (the kernel clears setgid
    -- for a group the user is not in, BSDs refuse a sticky bit to an
    -- ordinary user), and then the ordinary bits are what is kept.
    if written and existing then
        local set, chmod_err = uv.fs_fchmod(fd, full_mode)
        if not set and full_mode ~= perms then set, chmod_err = uv.fs_fchmod(fd, perms) end
        if not set then written, write_err = false, tostring(chmod_err or "could not set the file's mode") end
    end
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
