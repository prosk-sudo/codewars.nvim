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
---  * Unknown is not junk. The cache is "damaged" only when it was read in full
---    from a regular file and is empty or does not decode; a cache that could
---    not be read at all (permission, an I/O error, a descriptor that is not what
---    was checked) is unknown, and nothing is written over it: a read recovers
---    nothing, a write is refused. Likewise a .bak that cannot be read is
---    unknown: next to a cache that is no good it may be the one good copy, so
---    the write is refused and neither file is touched. Only a .bak that was
---    read in full and does not decode, one beside a cache that decodes, or a
---    symlink or other non-regular file, is ever removed or replaced.
---  * The copy outlives the write only when the old bytes could not be put back
---    (or the editor died mid-write). Then it is the one good copy of the
---    previous cache, and no later write replaces it with a cache that does not
---    decode: it stays the backup, and goes only once a write has fully landed.
---    Removing it then is part of the write succeeding: if it cannot be
---    unlinked it is emptied (an empty file does not decode, so it can never be
---    recovered from), and if it cannot be emptied either the write is reported
---    as failed, with the new data said to be written and the stale backup where.
---  * Nothing is opened blind. Files are opened without blocking, for reading
---    (O_RDONLY|O_NONBLOCK) and for writing (O_WRONLY|O_NONBLOCK, never O_TRUNC),
---    so one swapped for a pipe cannot hang the editor; the descriptor is then
---    checked (a regular file, the very one that was read or lstat-ed) before a
---    byte is read, and only then is it truncated and written.
---  * An existing .bak is never opened for writing to make a new copy, as that
---    would follow a symlink planted at the predictable name. A stale one, or
---    one that is a symlink or other non-regular file, is unlinked (which removes
---    a link, not its target) and the new copy is created exclusively. It is
---    never *read* through a symlink either.
---  * Only a writer ever removes a .bak (its own, once its write landed, or a
---    stale one it replaces). A reader never does: a cache that reads fine is no
---    proof that another process is not between copying it and rewriting it.
---
--- Threat model. This protects against failed or partial writes (a full disk, I/O
--- errors, a crash mid-write), transient read errors, and leftover or stale
--- backups. It assumes the cache directory is the user's own (`stdpath("cache")`)
--- and is not writable by other accounts. Out of scope:
---  * a concurrent process with write access to that directory racing the plugin
---    between a check and an open (planting a symlink, swapping a file): anyone
---    who can write there can already change the user's caches directly;
---  * a shared (sticky) directory holding a backup owned by another user, which
---    this process may not be able to remove;
---  * two Neovim instances, or a reader and a writer, using one cache at the same
---    moment: they are not coordinated, as they were not before there were backups.
--- What holds regardless: the plugin never writes through a symlink it created or
--- followed for a backup itself (O_EXCL, lstat plus identity checks); every open
--- is non-blocking and checked on its descriptor; and a failed write never loses
--- the previous cache.
local uv = vim.uv or vim.loop

local M = {}

local SUFFIX = ".bak"
local DEFAULT_MODE = 438 -- 0666: what a new file is created with, before the umask trims it
local PERMISSION_BITS = 511 -- 0777
local READ_CHUNK = 65536

-- Opening a pipe for reading waits until something opens its other end, and for
-- writing until something opens it for reading, so a file swapped for one just
-- before it is opened would hang the editor for good. O_NONBLOCK makes the open
-- return at once (reading, or an ENXIO error when writing; it does nothing to a
-- regular file) and the descriptor is checked before anything is done with it.
-- luv (Neovim 0.9 and up) takes integer flags and exposes O_RDONLY, O_WRONLY,
-- O_NONBLOCK, O_CREAT, O_EXCL, O_TRUNC and fs_ftruncate, but not O_NOFOLLOW: it is
-- used only if a build has it, and the lstat before the open plus the inode check
-- after it do the work otherwise. A luv without `constants` falls back to opening
-- by name ("r", "r+", "w", "wx"), which can block on a pipe but has the same checks.
local constants = uv.constants or {}
local READ_FLAGS = bit.bor(constants.O_RDONLY or 0, constants.O_NONBLOCK or 0)
local READ_BACKUP_FLAGS = bit.bor(READ_FLAGS, constants.O_NOFOLLOW or 0)

--- How a file is opened for writing: where it is, nothing is truncated by the open.
---@param create "create"|"exclusive"|nil create it if it is not there; and, when exclusive, only then
---@return integer|string
local function write_flags(create)
    if not constants.O_WRONLY then
        return create == "exclusive" and "wx" or create and "w" or "r+"
    end
    local flags = bit.bor(constants.O_WRONLY, constants.O_NONBLOCK or 0)
    if create then flags = bit.bor(flags, constants.O_CREAT or 0) end
    if create == "exclusive" then flags = bit.bor(flags, constants.O_EXCL or 0) end
    return flags
end

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

---@param stat table? what fstat says of the open descriptor
---@param expect table? the stat taken earlier, when the file must be that very one
---@return string? why the descriptor is not fit to be read or written
local function unfit(stat, expect)
    if not stat then return "it could not be examined" end
    if stat.type ~= "file" then return "it is not a regular file" end
    if expect and (stat.ino ~= expect.ino or stat.dev ~= expect.dev) then return "it changed while being opened" end
end

---@class cw.cache.WriteOpts
---@field mode integer? permission bits a new file is created with
---@field exact boolean? also set the file to exactly `mode`, whatever the umask took off
---@field create "create"|"exclusive"|nil create the file if it is not there, or only if it is not
---@field identity table? a stat the descriptor must match (inode and device): the file that was read

--- Open `path` for writing without blocking and without truncating, check the
--- descriptor, and only then truncate it, write all of `data`, flush it and close
--- it. A disk that is full or gone often says so only when flushed or closed.
---@param path string
---@param data string
---@param opts cw.cache.WriteOpts?
---@return boolean ok
---@return string? err
---@return boolean touched whether the file was created or truncated, so whether it may need putting back
local function write_file(path, data, opts)
    opts = opts or {}
    local fd, err = uv.fs_open(path, write_flags(opts.create), opts.mode or DEFAULT_MODE)
    if not fd then return false, err, false end
    local problem = unfit(uv.fs_fstat(fd), opts.identity)
    if problem then
        uv.fs_close(fd)
        return false, problem, false
    end
    local ok
    ok, err = uv.fs_ftruncate(fd, 0)
    if ok and opts.exact then ok, err = uv.fs_fchmod(fd, opts.mode) end
    if ok then ok, err = write_all(fd, data) end
    if ok then ok, err = uv.fs_fsync(fd) end
    local closed, close_err = uv.fs_close(fd)
    if ok and not closed then ok, err = false, close_err end
    return ok == true, err, true
end

--- The bytes of a regular file. The open cannot block, and the descriptor is
--- checked (a regular file, and with `expect`, the very file that was
--- lstat-ed: one swapped for a link, a pipe or another file since is refused)
--- before a byte is read from it.
---@param path string
---@param expect table? uv stat of `path` taken just before; the open then also refuses a symlink where it can
---@return string? bytes
---@return table|string|nil stat of the descriptor when read; why not, when not
---@return string? name of the error when the open failed ("ENOENT"...)
local function read_file(path, expect)
    local fd, err, name = uv.fs_open(path, expect and READ_BACKUP_FLAGS or READ_FLAGS, DEFAULT_MODE)
    if not fd then return nil, err, name end
    local stat = uv.fs_fstat(fd)
    local problem = unfit(stat, expect)
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
    return table.concat(chunks), stat
end

--- The cache file as a read finds it. Only "read" and "absent" are facts about
--- what is there; "unreadable" is not one, and nothing may be written over it.
---  * "absent": there is nothing at the path (ENOENT; a dangling symlink too)
---  * "read": a regular file read in full; `detail` is its bytes, and `stat` the
---    descriptor's, which a write must find again on its own descriptor
---  * "unreadable": anything else (permission, an I/O error, a descriptor that is
---    not a regular file); `detail` is why
---@param file string absolute path
---@return "absent"|"read"|"unreadable" state
---@return string? detail
---@return table? stat
function M.read_main(file)
    local bytes, stat_or_err, name = read_file(file)
    if bytes then return "read", bytes, stat_or_err end
    if name == "ENOENT" then return "absent" end
    return "unreadable", tostring(stat_or_err)
end

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
    if not bytes then return "unreadable", tostring(err) end
    return "read", bytes
end

---@alias cw.cache.BackupState "absent"|"foreign"|"unreadable"|"good"|"unusable"

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
    local ok, err, created = write_file(bak, original, { mode = mode, exact = true, create = "exclusive" })
    if not ok and created then uv.fs_unlink(bak) end
    return ok, err, note
end

--- The write has landed: the backup is stale now, and must not outlive it, or a
--- later damaged or unreadable cache would be "recovered" to what was there
--- before. Unlink it; if that fails, empty it (an empty file does not decode, so
--- it can never be recovered from); if that fails too, say where it is.
---@param bak string
---@return boolean ok
---@return string? message a note when it had to be emptied, why it could not be when not ok
local function discard_backup(bak)
    local unlinked, unlink_err, name = uv.fs_unlink(bak)
    if unlinked or name == "ENOENT" then return true end

    -- Only ENOENT means it is gone. Any other failure to look is "unknown": it
    -- cannot be emptied safely (there is no identity to check the open against)
    -- and must not be reported as removed.
    local stat, stat_err, stat_name = uv.fs_lstat(bak)
    if not stat and stat_name == "ENOENT" then return true end
    local emptied = false
    local empty_err
    if not stat then
        empty_err = "it could not be examined: " .. tostring(stat_err)
    elseif stat.type ~= "file" then
        empty_err = "it is not a regular file"
    else
        emptied, empty_err = write_file(bak, "", { identity = stat })
    end
    if emptied then
        return true, ("Could not remove %s (%s); emptied it instead, so it cannot be recovered from."):format(
            bak, tostring(unlink_err))
    end
    return false, ("the new data was written, but a stale backup at %s could not be removed (%s) or emptied (%s); "
        .. "delete it by hand"):format(bak, tostring(unlink_err), tostring(empty_err))
end

---@param first string?
---@param second string?
---@return string?
local function join(first, second)
    if first and second then return first .. " " .. second end
    return first or second
end

--- Nothing is at `file`: write it directly, and take what was written away
--- again if it did not all land. A backup left at the name (a good copy, or one
--- that cannot be read and so may be one) stays until the new file has landed,
--- and is stale, so gone, once it has.
local function write_new(file, bytes, parse)
    local bak = M.backup_path(file)
    local state = inspect_backup(bak, parse)
    local ok, err, touched = write_file(file, bytes, { create = "create" })
    if not ok then
        if touched then uv.fs_unlink(file) end
        return false, err
    end
    if state ~= "good" and state ~= "unreadable" then return true end
    local gone, message = discard_backup(bak)
    if not gone then return false, message end
    return true, nil, message
end

---@param file string
---@param err string?
---@return string
local function not_backed_up(file, err)
    return ("could not back up %s before writing it (%s); it was left as it was"):format(file, tostring(err))
end

--- `file` exists and was read, as `original`, on a descriptor that stat'd as
--- `identity`: back it up, write it in place, restore on failure.
local function write_over(file, bytes, original, identity, parse)
    local bak = M.backup_path(file)
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
        ok, err, note = make_backup(bak, original, bit.band(identity.mode, PERMISSION_BITS), state, kind)
        if not ok then return false, not_backed_up(file, err), note end
        kept = nil
    end

    local ok, err, truncated = write_file(file, bytes, { identity = identity })
    if ok then
        local gone, message = discard_backup(bak)
        if not gone then return false, message, note end
        return true, nil, join(note, message)
    end
    if not truncated then
        -- Refused before anything changed (a read-only file, a file that is no
        -- longer the one that was read): nothing to put back. Our own copy goes;
        -- a good one left earlier still guards the cache.
        if not kept then uv.fs_unlink(bak) end
        return false, err, note
    end

    local restored, restore_err = write_file(file, restore_from, { identity = identity })
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
    local state, detail, stat = M.read_main(file)
    if state == "absent" then return write_new(file, bytes, parse) end
    -- Not known to be damaged, and so not to be written over without a backup of it.
    if state == "unreadable" then return false, not_backed_up(file, "it could not be read: " .. detail) end
    return write_over(file, bytes, detail, stat, parse)
end

--- A read found `file` absent, or read in full and empty or undecodable: if a
--- good copy is at the backup's name, write it back into the file. The backup
--- is left where it is.
---@param file string
---@param parse fun(text: string): any? the data in `text`, nil when it is not usable
---@param main_stat table? the descriptor's stat when `file` was read (it is not absent)
---@return any? recovered the data of the backup, nil when it was not used
---@return string? err why it could not be written back into `file`
function M.settle(file, parse, main_stat)
    local bak = M.backup_path(file)
    -- Not read in full from a regular file (absent, foreign, unreadable): it is
    -- unknown, so nothing is touched.
    local state, text = read_backup(bak)
    if state ~= "read" then return nil end
    local data = parse(text)
    if data == nil then return nil end

    local opts = { identity = main_stat }
    if not main_stat then
        local stat = uv.fs_stat(bak)
        local mode = stat and bit.band(stat.mode, PERMISSION_BITS)
        opts = { create = "create", mode = mode, exact = mode ~= nil }
    end
    local restored, err = write_file(file, text, opts)
    if restored then return data end
    return data, tostring(err)
end

return M
