--- Writing a cache file in place without risking the cache that is already
--- there. The file is never replaced by a new one, so its inode, owner, group,
--- exact mode, ACLs and read-only state are all still its own afterwards.
--- This is Vim's `backupcopy=yes`: copy the old bytes to <file>.bak, rewrite the
--- file in place, put the old bytes back if that fails, and drop the copy.
---
--- The rules this keeps:
---  * No backup, no write. A cache that cannot be copied first (the directory
---    cannot be written, the disk is full, the file cannot be read) is left
---    exactly as it is and the write is refused, never done without the copy:
---    a write that then ran out of space would destroy the only copy.
---  * The copy outlives the write only when the old bytes could not be put back
---    (or the editor died mid-write). Then it is the one good copy of the
---    previous cache, and no later write replaces it with a cache that does not
---    decode: it stays the backup, and goes only once a write has fully landed.
---  * An existing .bak is never opened for writing, as that would follow a
---    symlink planted at the predictable name. A stale one, or one that is a
---    symlink or other non-regular file, is unlinked (which removes a link, not
---    its target) and the new copy is created exclusively. It is never *read*
---    through a symlink either.
---  * Only a writer ever removes a .bak (its own, once its write landed, or a
---    stale one it replaces). A reader never does: a cache that reads fine is no
---    proof that another process is not between copying it and rewriting it.
---
--- Two processes writing one cache at the same moment, or one reading while the
--- other writes, are not coordinated; that is out of scope here, as it was
--- before there were backups.
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

--- Whether anything is at the backup's name, a dangling symlink included.
---@param file string
---@return boolean
function M.has_backup(file)
    return uv.fs_lstat(M.backup_path(file)) ~= nil
end

--- Remove the backup of a cache that is being deleted, so that the next read
--- does not "recover" what was deleted on purpose. Unlinks: a symlink goes,
--- its target does not.
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

---@class cw.cache.WriteOpts
---@field mode integer? permission bits a new file is created with
---@field exact boolean? also set the file to exactly `mode`, whatever the umask took off
---@field flags string? how to open it; "w" (create or truncate) unless given. "wx" fails on anything already there

--- Open `path` for writing, write all of `data`, flush it and close it. A disk
--- that is full or gone often says so only when flushed or closed.
---@param path string
---@param data string
---@param opts cw.cache.WriteOpts?
---@return boolean ok
---@return string? err
---@return boolean opened whether the file was opened, so created (or truncated)
local function write_file(path, data, opts)
    opts = opts or {}
    local fd, err = uv.fs_open(path, opts.flags or "w", opts.mode or DEFAULT_MODE)
    if not fd then return false, err, false end
    local ok = true
    if opts.exact then ok, err = uv.fs_fchmod(fd, opts.mode) end
    if ok then ok, err = write_all(fd, data) end
    if ok then ok, err = uv.fs_fsync(fd) end
    local closed, close_err = uv.fs_close(fd)
    if ok and not closed then ok, err = false, close_err end
    return ok == true, err, true
end

--- The bytes of a file. With `expect` (a stat of `path`), only that very file:
--- one swapped for a symlink since is refused.
---@param path string
---@param expect table? uv stat of `path` taken just before
---@return string? bytes nil when the file cannot be read
local function read_file(path, expect)
    local fd = uv.fs_open(path, "r", DEFAULT_MODE)
    if not fd then return nil end
    local stat = expect and uv.fs_fstat(fd)
    if expect and not (stat and stat.ino == expect.ino and stat.dev == expect.dev) then
        uv.fs_close(fd)
        return nil
    end
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

--- The backup's bytes, from a regular file only: not through a symlink, and
--- not from a directory, a device or a pipe.
---@param bak string
---@return string? bytes
---@return string? kind what is there when it is not a regular file
local function read_backup(bak)
    local stat = uv.fs_lstat(bak)
    if not stat then return nil end
    if stat.type ~= "file" then return nil, stat.type end
    return read_file(bak, stat)
end

---@alias cw.cache.BackupState "absent"|"foreign"|"good"|"unusable"

--- What is at the backup's name: nothing, something that is not a regular
--- file, a regular file that decodes (a good copy), or one that does not.
---@param bak string
---@param parse fun(text: string): any?
---@return cw.cache.BackupState state
---@return string? bytes of a good copy
---@return string? kind what a foreign thing is
local function inspect_backup(bak, parse)
    local bytes, kind = read_backup(bak)
    if kind then return "foreign", nil, kind end
    if bytes and parse(bytes) ~= nil then return "good", bytes end
    if uv.fs_lstat(bak) then return "unusable" end
    return "absent"
end

--- Copy `original` to a fresh backup, with the original's permission bits (so
--- a 0600 cache does not leak into a 0644 copy). Whatever is at the name is
--- unlinked first; the copy is created exclusively, so anything that appears
--- there in between makes this fail instead of being followed.
---@param bak string
---@param original string
---@param mode integer
---@param state cw.cache.BackupState what was at the name
---@param kind string? what it was, when not a regular file
---@return boolean ok
---@return string? err
---@return string? note something to tell the user
local function make_backup(bak, original, mode, state, kind)
    local note
    if state ~= "absent" then
        local ok, err = uv.fs_unlink(bak)
        if not ok then return false, ("%s could not be cleared away (%s)"):format(bak, tostring(err)) end
        if state == "foreign" then
            note = ("Removed %s: it was a %s, not a backup of the cache beside it."):format(
                bak, kind == "link" and "symlink" or kind)
        end
    end
    local ok, err, created = write_file(bak, original, { mode = mode, exact = true, flags = "wx" })
    if not ok and created then uv.fs_unlink(bak) end
    return ok, err, note
end

--- Nothing is at `file` yet: write it directly, and take what was written
--- away again if it did not all land. A good copy left at the backup's name
--- stays until it has; it is gone once it has.
local function write_new(file, bytes, parse)
    local bak = M.backup_path(file)
    local state = inspect_backup(bak, parse)
    local ok, err, created = write_file(file, bytes)
    if not ok and created then uv.fs_unlink(file) end
    if ok and state == "good" then uv.fs_unlink(bak) end
    return ok, err
end

---@param file string
---@param err string?
---@return string
local function not_backed_up(file, err)
    return ("could not back up %s before writing it (%s); it was left as it was"):format(file, tostring(err))
end

--- `file` exists, with `stat`: back it up, write it in place, restore on failure.
local function write_over(file, bytes, stat, parse)
    local bak = M.backup_path(file)
    local original = read_file(file)
    if not original then return false, not_backed_up(file, "it could not be read") end

    -- A good copy already at the backup's name, with a cache that is no good
    -- beside it, IS the backup: keep it as it is, restore from it, and remove
    -- it only after the new bytes have landed. Anything else there is replaced.
    local state, kept, kind = inspect_backup(bak, parse)
    local restore_from, note = original, nil
    if state == "good" and parse(original) == nil then
        restore_from = kept
    else
        local ok, err
        ok, err, note = make_backup(bak, original, bit.band(stat.mode, PERMISSION_BITS), state, kind)
        if not ok then return false, not_backed_up(file, err), note end
        kept = nil
    end

    local ok, err, truncated = write_file(file, bytes)
    if ok then
        uv.fs_unlink(bak)
        return true, nil, note
    end
    if not truncated then
        -- Refused before anything changed (a read-only file): nothing to put
        -- back. Our own copy goes; a good one left earlier still guards the cache.
        if not kept then uv.fs_unlink(bak) end
        return false, err, note
    end

    local restored, restore_err = write_file(file, restore_from)
    if restored then
        uv.fs_unlink(bak)
        return false, err, note
    end
    return false, ("%s; the previous contents could not be put back (%s) and are kept in %s"):format(
        tostring(err), tostring(restore_err), bak), note
end

--- Write `bytes` to `file`, keeping the previous contents if that fails.
---@param file string absolute path
---@param bytes string
---@param parse fun(text: string): any? the data in `text`, nil when it is not usable
---@return boolean ok
---@return string? err
---@return string? note something worth telling the user, whether or not it worked
function M.write(file, bytes, parse)
    local stat = uv.fs_stat(file)
    if not stat then return write_new(file, bytes, parse) end
    return write_over(file, bytes, stat, parse)
end

--- A read found `file` unusable: if a good copy is at the backup's name, write
--- it back into the file. The backup is left where it is.
---@param file string
---@param parse fun(text: string): any? the data in `text`, nil when it is not usable
---@return any? recovered the data of the backup, nil when it was not used
---@return string? err why it could not be written back into `file`
function M.settle(file, parse)
    local bak = M.backup_path(file)
    local text = read_backup(bak)
    if not text then return nil end
    local data = parse(text)
    if data == nil then return nil end

    local mode
    if not uv.fs_stat(file) then
        local stat = uv.fs_stat(bak)
        mode = stat and bit.band(stat.mode, PERMISSION_BITS)
    end
    local restored, err = write_file(file, text, { mode = mode, exact = mode ~= nil })
    if restored then return data end
    return data, tostring(err)
end

return M
