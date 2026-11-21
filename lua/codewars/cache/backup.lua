--- Writing a cache file in place without risking the cache that is already
--- there. The file is never replaced by a new one, so its inode, owner, group,
--- exact mode, ACLs and read-only state are all still its own afterwards.
--- This is Vim's `backupcopy=yes`: copy the old bytes to <file>.bak, rewrite the
--- file in place, put the old bytes back if that fails, and drop the copy.
---
--- The copy outlives the write only when the old bytes could not be put back
--- (or the editor died mid-write); then it is the one copy of the previous cache,
--- and settle() recovers from it on the next read.
local uv = vim.uv or vim.loop

local M = {}

local SUFFIX = ".bak"
local DEFAULT_MODE = 438 -- 0666: what a new file is created with, before the umask trims it
local PERMISSION_BITS = 511 -- 0777
local READ_CHUNK = 65536

---@param file string
---@return string
function M.backup_path(file)
    return file .. SUFFIX
end

--- Whether a directory entry is a cache backup. Every scan over a cache or
--- solution folder skips these: they are never an entry of their own.
---@param name string
---@return boolean
function M.is_backup(name)
    return name:sub(-#SUFFIX) == SUFFIX
end

--- `path` as the absolute string the fs calls take.
---@param path Path|string
---@return string
function M.file_name(path)
    if type(path) == "string" then return path end
    local ok, absolute = pcall(path.absolute, path)
    return ok and absolute or tostring(path)
end

---@param file string
---@return boolean
function M.has_backup(file)
    return uv.fs_stat(M.backup_path(file)) ~= nil
end

--- Remove the backup of a cache that is being deleted, so that the next read
--- does not "recover" what was deleted on purpose.
---@param path Path|string
function M.drop(path)
    uv.fs_unlink(M.backup_path(M.file_name(path)))
end

--- Write all of `data` at the start of the open `fd`. A short count is
--- continued from where it stopped; no progress at all is a failure, not a loop.
---@return boolean ok
---@return string? err
local function write_all(fd, data)
    local written = 0
    while written < #data do
        local rest = written == 0 and data or data:sub(written + 1)
        local count, err = uv.fs_write(fd, rest, written)
        if not count then return false, err end
        if count <= 0 then return false, "write made no progress" end
        written = written + count
    end
    return true
end

--- Open `path` for writing (truncating it), write all of `data`, flush it and
--- close it. A disk that is full or gone often says so only when flushed or closed.
---@param path string
---@param data string
---@param mode integer? permission bits a new file is created with
---@param exact boolean? also set the file to exactly `mode`, whatever the umask took off
---@return boolean ok
---@return string? err
---@return boolean opened whether the file was opened, so created or truncated
local function write_file(path, data, mode, exact)
    local fd, err = uv.fs_open(path, "w", mode or DEFAULT_MODE)
    if not fd then return false, err, false end
    local ok = true
    if exact then ok, err = uv.fs_fchmod(fd, mode) end
    if ok then ok, err = write_all(fd, data) end
    if ok then ok, err = uv.fs_fsync(fd) end
    local closed, close_err = uv.fs_close(fd)
    if ok and not closed then ok, err = false, close_err end
    return ok == true, err, true
end

---@param path string
---@return string? bytes nil when the file cannot be read
local function read_file(path)
    local fd = uv.fs_open(path, "r", DEFAULT_MODE)
    if not fd then return nil end
    local chunks, offset = {}, 0
    while true do
        local chunk = uv.fs_read(fd, READ_CHUNK, offset)
        if not chunk then
            uv.fs_close(fd)
            return nil
        end
        if chunk == "" then break end
        chunks[#chunks + 1] = chunk
        offset = offset + #chunk
    end
    uv.fs_close(fd)
    return table.concat(chunks)
end

--- Nothing is at `file` yet: write it directly, and take what was written
--- away again if it did not all land.
local function write_new(file, bytes)
    local ok, err, created = write_file(file, bytes)
    if not ok and created then uv.fs_unlink(file) end
    return ok, err
end

--- `file` exists, with `stat`: back it up, write it in place, restore on failure.
local function write_over(file, bytes, stat)
    local bak = M.backup_path(file)
    local original = read_file(file)
    local backed_up = false
    if original then
        -- With the original's own permission bits, so a 0600 cache does not
        -- leak into a 0644 copy.
        local ok, _, opened = write_file(bak, original, bit.band(stat.mode, PERMISSION_BITS), true)
        backed_up = ok
        if not ok and opened then uv.fs_unlink(bak) end
    end
    -- No backup (the directory is not writable, the disk is full, the file
    -- cannot be read): write in place anyway. That is what this did before
    -- there were backups, so it is no worse than that.

    local ok, err, truncated = write_file(file, bytes)
    if ok then
        if backed_up then uv.fs_unlink(bak) end
        return true
    end
    if not backed_up then return false, err end
    if not truncated then
        -- Refused before anything changed (a read-only file): nothing to put back.
        uv.fs_unlink(bak)
        return false, err
    end

    local restored, restore_err = write_file(file, original)
    if restored then
        uv.fs_unlink(bak)
        return false, err
    end
    return false, ("%s; the previous contents could not be put back (%s) and are kept in %s"):format(
        tostring(err), tostring(restore_err), bak)
end

--- Write `bytes` to `file`, keeping the previous contents if that fails.
---@param file string absolute path
---@param bytes string
---@return boolean ok
---@return string? err
function M.write(file, bytes)
    local stat = uv.fs_stat(file)
    if not stat then return write_new(file, bytes) end
    return write_over(file, bytes, stat)
end

--- A backup is beside `file`: use it or clear it away. When `file` is usable
--- the backup is stale (the editor died between the write and removing it).
--- When it is not, and the backup is, the backup is written back into the file.
---@param file string
---@param main_ok boolean whether `file` holds something usable
---@param parse fun(text: string): any? the data in `text`, nil when it is not usable
---@return any? recovered the data of the backup, nil when it was not used
---@return string? err why the backup could not be written back into `file`; it is kept then
function M.settle(file, main_ok, parse)
    local bak = M.backup_path(file)
    local text = read_file(bak)
    if not text then return nil end
    if main_ok then
        uv.fs_unlink(bak)
        return nil
    end
    local data = parse(text)
    if data == nil then return nil end

    local exists = uv.fs_stat(file) ~= nil
    local bak_stat = not exists and uv.fs_stat(bak) or nil
    local mode = bak_stat and bit.band(bak_stat.mode, PERMISSION_BITS)
    local restored, err = write_file(file, text, mode, mode ~= nil)
    if restored then
        uv.fs_unlink(bak)
        return data
    end
    return data, tostring(err)
end

return M
