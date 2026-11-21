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
---  * A .bak that cannot be read (permission, an I/O error, anything short of a
---    full read of a regular file) is unknown, not junk: next to a cache that is
---    no good it may be the one good copy, so the write is refused and neither
---    file is touched, and a read recovers nothing from it. Only a .bak that was
---    read in full and does not decode, one beside a cache that decodes, or a
---    symlink or other non-regular file, is ever removed or replaced.
---  * Nothing is read blind: every file read here is opened without blocking and its
---    descriptor checked (a regular file, the very one that was lstat-ed) before a
---    byte is read, so one swapped for a pipe cannot hang the editor.
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

-- Opening a pipe for reading waits until something opens its other end, so a file
-- swapped for one just before it is opened would hang the editor for good.
-- O_NONBLOCK makes the open return at once (it does nothing to a regular file) and
-- the descriptor is checked before a byte is read. luv (Neovim 0.9 and up) takes
-- integer flags and exposes O_NONBLOCK, but not O_NOFOLLOW: it is used only if a
-- build has it, and the lstat before the open plus the inode check after it do
-- the work otherwise. A luv without `constants` falls back to a plain read-only
-- open, which still has those two checks.
local constants = uv.constants or {}
local READ_FLAGS = bit.bor(constants.O_RDONLY or 0, constants.O_NONBLOCK or 0)
local READ_BACKUP_FLAGS = bit.bor(READ_FLAGS, constants.O_NOFOLLOW or 0)

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

---@param stat table? what fstat says of the open descriptor
---@param expect table? the lstat taken just before the open, when the file must be that very one
---@return string? why the descriptor is not fit to be read
local function unfit(stat, expect)
    if not stat then return "it could not be examined" end
    if stat.type ~= "file" then return "it is not a regular file" end
    if expect and (stat.ino ~= expect.ino or stat.dev ~= expect.dev) then return "it changed while being opened" end
end

--- The bytes of a regular file. The open cannot block, and the descriptor is
--- checked (a regular file, and with `expect`, the very file that was
--- lstat-ed: one swapped for a link, a pipe or another file since is refused)
--- before a byte is read from it.
---@param path string
---@param expect table? uv stat of `path` taken just before; the open then also refuses a symlink where it can
---@return string? bytes
---@return string? err why it could not be read
local function read_file(path, expect)
    local fd, err = uv.fs_open(path, expect and READ_BACKUP_FLAGS or READ_FLAGS, DEFAULT_MODE)
    if not fd then return nil, err end
    local problem = unfit(uv.fs_fstat(fd), expect)
    if problem then
        uv.fs_close(fd)
        return nil, problem
    end
    local chunks, offset = {}, 0
    while true do
        local chunk, read_err = uv.fs_read(fd, READ_CHUNK, offset)
        if not chunk then
            uv.fs_close(fd)
            return nil, read_err
        end
        if chunk == "" then break end
        chunks[#chunks + 1] = chunk
        offset = offset + #chunk
    end
    uv.fs_close(fd)
    return table.concat(chunks)
end

--- The bytes of a cache file, nil when it is not a regular file that reads in full.
---@param file string absolute path
---@return string? bytes
function M.read(file)
    return (read_file(file))
end

---@alias cw.cache.BackupState "absent"|"foreign"|"unreadable"|"good"|"unusable"

--- What is at the backup's name, from lstat first (never through a symlink):
---  * "absent": nothing
---  * "foreign": not a regular file; `detail` is what it is
---  * "unreadable": a regular file that could not be opened or read in full;
---    `detail` is why. Unknown, not junk: it may be the one good copy.
---  * "read": a regular file read in full; `detail` is its bytes
---@param bak string
---@return "absent"|"foreign"|"unreadable"|"read" state
---@return string? detail
local function read_backup(bak)
    local stat = uv.fs_lstat(bak)
    if not stat then return "absent" end
    if stat.type ~= "file" then return "foreign", stat.type end
    local bytes, err = read_file(bak, stat)
    if not bytes then return "unreadable", err end
    return "read", bytes
end

--- `read_backup`, with a regular file that was read in full sorted into one
--- that decodes (a good copy; `detail` is its bytes) and one that does not.
---@param bak string
---@param parse fun(text: string): any?
---@return cw.cache.BackupState state
---@return string? detail
local function inspect_backup(bak, parse)
    local state, detail = read_backup(bak)
    if state ~= "read" then return state, detail end
    if parse(detail) ~= nil then return "good", detail end
    return "unusable"
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
    local original, read_err = read_file(file)
    if not original then return false, not_backed_up(file, "it could not be read: " .. tostring(read_err)) end
    local function decodes() return parse(original) ~= nil end

    -- A copy that could not be read is unknown, not junk: beside a cache that is
    -- no good it may be the one good copy, so nothing is touched.
    local state, kept = inspect_backup(bak, parse)
    if state == "unreadable" and not decodes() then
        return false, not_backed_up(file, ("%s could not be read (%s), and may be the only good copy"):format(
            bak, tostring(kept)))
    end

    -- A good copy already at the backup's name, with a cache that is no good
    -- beside it, IS the backup: keep it as it is, restore from it, and remove
    -- it only after the new bytes have landed. Anything else there is replaced.
    local kind = state == "foreign" and kept or nil
    local restore_from, note = original, nil
    if state == "good" and not decodes() then
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
    -- Not read in full from a regular file (absent, foreign, unreadable): it is
    -- unknown, so nothing is touched.
    local state, text = read_backup(bak)
    if state ~= "read" then return nil end
    local data = parse(text)
    if data == nil then return nil end

    local main = uv.fs_stat(file)
    -- Opening a pipe or a device for writing could wait for ever.
    if main and main.type ~= "file" then return data, "it is not a regular file" end
    local mode
    if not main then
        local stat = uv.fs_stat(bak)
        mode = stat and bit.band(stat.mode, PERMISSION_BITS)
    end
    local restored, err = write_file(file, text, { mode = mode, exact = mode ~= nil })
    if restored then return data end
    return data, tostring(err)
end

return M
