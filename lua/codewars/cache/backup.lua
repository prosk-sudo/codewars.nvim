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
---  * Recovery runs only over a cache that exists and is damaged: read in full
---    from a regular file, and empty or not decodable. Every write over an existing
---    cache is in place, so an interrupted one leaves the cache present and damaged,
---    never absent; a cache that is absent was deleted (by the plugin, or by
---    hand), and a leftover backup must not bring it back. So a read of an absent
---    cache returns nothing and touches nothing, and the next write discards the
---    stale backup first and only then creates the cache afresh, so a crash partway
---    through creating it leaves nothing from the deleted cache to recover.
---  * Unknown is not junk. A cache that could not be read at all (permission, an
---    I/O error, a descriptor that is not what was checked) is unknown, not
---    damaged, and nothing is written over it: a read recovers nothing, a write
---    is refused. Likewise a .bak that cannot be read is
---    unknown: next to a cache that is no good it may be the one good copy, so
---    the write is refused and neither file is touched. Only a .bak that was
---    read in full and does not decode, one beside a cache that decodes, or a
---    symlink or other non-regular file, is ever removed or replaced.
---  * A backup is only trusted if it proves it is complete. It is written as one
---    header line, `CWBAK1 <byte-length> <sha256-hex>`, then the original bytes. A
---    crash while it is being created (the failure clean-up does not run when the
---    process dies) can leave a prefix that is itself valid JSON, so a backup is
---    "good" only if the header parses, the payload has exactly that many bytes, the
---    checksum matches, and the payload then decodes. Anything else (a missing or
---    garbled header, a short payload, a checksum mismatch, a file with no header)
---    is undecodable, never used for recovery, and replaced or discarded under the
---    rules below. Recovery and restores write back only the verified payload,
---    never the header.
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
---  * A cache that is absent is written by creating it exclusively (O_CREAT|O_EXCL), never
---    through whatever appears at its path after it was read. A dangling symlink
---    that is the configured cache is resolved one level and its target is
---    created (a link to a link is refused), and a failed write removes the file
---    that was created, never the link.
---  * Only ENOENT means something is absent. Any other error looking at a .bak (an
---    I/O error, a permission) leaves it unknown: a write is refused before it
---    writes anything, a read recovers nothing, and a removal is not reported done.
---  * Deleting a cache removes its backup (drop): unlink, else empty it, and only
---    if neither works is that reported, with the deletion going on.
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
---@param create boolean? create it, exclusively: it is not there, and is ours once the open has succeeded
---@return integer|string
local function write_flags(create)
    if not constants.O_WRONLY then return create and "wx" or "r+" end
    local flags = bit.bor(constants.O_WRONLY, constants.O_NONBLOCK or 0)
    if create then flags = bit.bor(flags, constants.O_CREAT or 0, constants.O_EXCL or 0) end
    return flags
end

local BACKUP_MAGIC = "CWBAK1"

--- A backup of `bytes`: a header line with their length and sha256, then the bytes.
---@param bytes string
---@return string
function M.frame_backup(bytes)
    return ("%s %d %s\n%s"):format(BACKUP_MAGIC, #bytes, vim.fn.sha256(bytes), bytes)
end

--- The bytes a backup holds, if it proves it is complete: the header parses, the
--- payload has exactly the length it names, and its checksum matches. nil for
--- anything else: a missing or garbled header, a short payload, a corrupt one, a
--- file that is not a backup at all. Whether the payload is a cache is another
--- question (it must decode).
---@param text string
---@return string? payload
function M.parse_backup(text)
    local newline = text:find("\n", 1, true)
    if not newline then return nil end
    local length, sum = text:sub(1, newline - 1):match("^" .. BACKUP_MAGIC .. " (%d+) (%x+)$")
    if not length then return nil end
    local payload = text:sub(newline + 1)
    if #payload ~= tonumber(length) then return nil end
    if vim.fn.sha256(payload) ~= sum then return nil end
    return payload
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

--- Whether `path` is rooted. Not vim.fn.isabsolutepath, which Neovim 0.9 and 0.10
--- do not have: a leading "/", and on Windows also a drive ("C:\\", "C:/") or a UNC
--- name ("\\\\host", "//host").
---@param path string
---@return boolean
function M.is_absolute(path)
    if path:sub(1, 1) == "/" then return true end
    if vim.fn.has("win32") ~= 1 then return false end
    return path:match("^%a:[\\/]") ~= nil or path:match("^[\\/][\\/]") ~= nil
end

--- `path` as the absolute string the fs calls take.
---@param path Path|string
---@return string
function M.file_name(path)
    if type(path) == "string" then return path end
    local ok, absolute = pcall(path.absolute, path)
    return ok and absolute or tostring(path)
end

--- Whether anything is at the backup's name, a dangling symlink included. An
--- error other than ENOENT reads as "no": it is only used to decide whether a read
--- may try to recover, and that recovers nothing from a backup it cannot examine.
---@param file string
---@return boolean
function M.has_backup(file)
    return uv.fs_lstat(M.backup_path(file)) ~= nil
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
---@field create boolean? create the file exclusively (O_CREAT|O_EXCL): once opened it is ours
---@field identity table? a stat the descriptor must match (inode and device): the file that was read

--- Open `path` for writing without blocking and without truncating, check the
--- descriptor, and only then truncate it, write all of `data`, flush it and close
--- it. A disk that is full or gone often says so only when flushed or closed.
---
--- A file that the open created (`create`) is ours from the moment it succeeds:
--- whatever fails after that (the descriptor check, ftruncate, fchmod, a write,
--- fsync, close) takes it away again, so no empty or partial file is left behind.
--- Once the descriptor has passed the check that proves it is the file we created,
--- what was written is emptied first (ftruncate and fsync, while it is still open),
--- and then the descriptor is closed and the path unlinked. If the unlink fails the
--- file is already empty, which never decodes, so a partial cache or backup cannot
--- be recovered from; the failure of the clean-up is added to the error, naming the
--- path. A file that was already there is never unlinked because a write to it
--- failed.
---@param path string
---@param data string
---@param opts cw.cache.WriteOpts?
---@return boolean ok
---@return string? err
---@return boolean touched whether an existing file was truncated, so whether it may need putting back
local function write_file(path, data, opts)
    opts = opts or {}
    local fd, err = uv.fs_open(path, write_flags(opts.create), opts.mode or DEFAULT_MODE)
    if not fd then return false, err, false end

    local ok
    local touched = false
    local stat, stat_err = uv.fs_fstat(fd)
    local problem = unfit(stat, opts.identity)
    if problem then
        ok, err = false, stat and problem or ("%s: %s"):format(problem, tostring(stat_err))
    else
        touched = true
        ok, err = uv.fs_ftruncate(fd, 0)
        if ok and opts.exact then ok, err = uv.fs_fchmod(fd, opts.mode) end
        if ok then ok, err = write_all(fd, data) end
        if ok then ok, err = uv.fs_fsync(fd) end
    end

    -- Ours, failed, and proved to be the file we created: empty it while it is open.
    local emptied
    if not ok and opts.create and touched then
        emptied = uv.fs_ftruncate(fd, 0) and uv.fs_fsync(fd) or false
    end
    local closed, close_err = uv.fs_close(fd)
    if ok and not closed then ok, err = false, close_err end
    if not ok and opts.create then
        local removed, unlink_err, name = uv.fs_unlink(path)
        if not removed and name ~= "ENOENT" then
            local state = "it is empty"
            if touched then
                state = emptied and "was emptied" or "could not be emptied; delete it by hand"
            end
            err = ("%s; the partial file at %s could not be removed (%s) and %s"):format(
                tostring(err), path, tostring(unlink_err), state)
        end
    end
    return ok == true, err, touched
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
---  * "absent": nothing: lstat says ENOENT, and only that does
---  * "unknown": lstat failed some other way (an I/O error, a permission); `detail`
---    is why. There may be a good copy there, so a write is refused and a read
---    recovers nothing
---  * "foreign": not a regular file; `detail` is what it is
---  * "unreadable": a regular file that could not be opened or read in full;
---    `detail` is why. Unknown, not junk: it may be the one good copy.
---  * "read": a regular file read in full; `detail` is its bytes
---@param bak string
---@return "absent"|"unknown"|"foreign"|"unreadable"|"read" state
---@return string? detail
local function read_backup(bak)
    local stat, stat_err, stat_name = uv.fs_lstat(bak)
    if not stat then
        if stat_name == "ENOENT" then return "absent" end
        return "unknown", tostring(stat_err)
    end
    if stat.type ~= "file" then return "foreign", stat.type end
    local bytes, err = read_file(bak, stat)
    if not bytes then return "unreadable", tostring(err) end
    return "read", bytes
end

---@alias cw.cache.BackupState "absent"|"unknown"|"foreign"|"unreadable"|"good"|"unusable"

--- `read_backup`, with a regular file that was read in full sorted into one
--- that is a complete backup of something that decodes (a good copy; `detail` is
--- that payload, without the header) and one that is not: no header, a short or
--- corrupt payload, or a payload that does not decode.
---@param bak string
---@param parse fun(text: string): any?
---@return cw.cache.BackupState state
---@return string? detail
local function inspect_backup(bak, parse)
    local state, detail = read_backup(bak)
    if state ~= "read" then return state, detail end
    local payload = M.parse_backup(detail)
    if payload and parse(payload) ~= nil then return "good", payload end
    return "unusable"
end

---@param bak string
---@param kind string what was there instead, from lstat ("link", "directory", ...)
---@return string
local function foreign_note(bak, kind)
    return ("Removed %s: it was a %s, not a backup of the cache beside it."):format(
        bak, kind == "link" and "symlink" or kind)
end

---@param bak string
---@param unlink_err string why it could not be unlinked
---@return string
local function emptied_note(bak, unlink_err)
    return ("Could not remove %s (%s); emptied it instead, so it cannot be recovered from."):format(bak, unlink_err)
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
        if state == "foreign" then note = foreign_note(bak, kind) end
    end
    local ok, err = write_file(bak, M.frame_backup(original), { mode = mode, exact = true, create = true })
    return ok, err, note
end

--- Get rid of a backup that must not be recovered from again. Unlink it; if that
--- fails with anything but ENOENT, empty it (an empty file does not decode, so
--- it can never be recovered from). Only ENOENT, from the unlink or from a look
--- afterwards, means it is gone: any other failure to look is "unknown", which
--- cannot be emptied safely (there is no identity to check the open against)
--- and is not reported as removed.
---@param bak string
---@return "gone"|"emptied"|"failed" outcome
---@return string? detail why the unlink failed when emptied; why it could neither be removed nor emptied when failed
local function remove_backup(bak)
    local unlinked, unlink_err, name = uv.fs_unlink(bak)
    if unlinked or name == "ENOENT" then return "gone" end

    local stat, stat_err, stat_name = uv.fs_lstat(bak)
    if not stat and stat_name == "ENOENT" then return "gone" end
    local emptied = false
    local empty_err
    if not stat then
        empty_err = "it could not be examined: " .. tostring(stat_err)
    elseif stat.type ~= "file" then
        empty_err = "it is not a regular file"
    else
        emptied, empty_err = write_file(bak, "", { identity = stat })
    end
    if emptied then return "emptied", tostring(unlink_err) end
    return "failed", ("could not be removed (%s) or emptied (%s)"):format(tostring(unlink_err), tostring(empty_err))
end

--- The write has landed: the backup is stale now, and must not outlive it, or a
--- later damaged or unreadable cache would be "recovered" to what was there
--- before. See remove_backup.
---@param bak string
---@return boolean ok
---@return string? message a note when it had to be emptied, why it could not be when not ok
local function discard_backup(bak)
    local outcome, detail = remove_backup(bak)
    if outcome == "gone" then return true end
    if outcome == "emptied" then return true, emptied_note(bak, detail) end
    return false, ("the new data was written, but a stale backup at %s %s; delete it by hand"):format(bak, detail)
end

--- Remove the backup of a cache that is being deleted, so that the next read
--- does not "recover" what was deleted on purpose. ENOENT is success; a backup
--- that cannot be unlinked is emptied instead; only if that fails too is it
--- `false`, with why. Unlinks, so a symlink goes and its target does not.
---@param path Path|string
---@return boolean ok
---@return string? why when not ok, a sentence naming the backup
function M.drop(path)
    local bak = M.backup_path(M.file_name(path))
    local outcome, detail = remove_backup(bak)
    if outcome == "failed" then return false, ("the backup at %s %s"):format(bak, detail) end
    return true
end

--- `drop` for a deletion the user asked for (a sign-out, a cache clear): the
--- deletion goes on whatever happens, and a backup that could be neither
--- removed nor emptied is reported.
---@param path Path|string
---@return boolean ok
function M.drop_or_warn(path)
    local ok, why = M.drop(path)
    if ok then return true end
    require("codewars.logger").warn(
        ("Clearing %s: %s; delete it by hand, or the cache that was cleared can come back."):format(
            M.file_name(path), why))
    return false
end

---@param first string?
---@param second string?
---@return string?
local function join(first, second)
    if first and second then return first .. " " .. second end
    return first or second
end

--- Where a cache that is absent is to be created, so that it is created
--- exclusively: nothing at the path, and then the path itself; or a dangling
--- symlink (a configured cache link whose target does not exist yet), and then
--- the path the link names, one level, resolved against the link's directory,
--- never created through the link. A link to a link, anything that has appeared
--- at the path or the target since it was read as absent, or anything that
--- cannot be examined, is refused.
---@param file string
---@return string? path
---@return string? why when no path
local function creation_target(file)
    local stat, err, name = uv.fs_lstat(file)
    if not stat then
        if name == "ENOENT" then return file end
        return nil, ("%s could not be examined (%s)"):format(file, tostring(err))
    end
    if stat.type ~= "link" then return nil, ("something appeared at %s after it was read as absent"):format(file) end

    local named, link_err = uv.fs_readlink(file)
    if not named then return nil, ("the link %s could not be read (%s)"):format(file, tostring(link_err)) end
    local target = M.is_absolute(named) and named or (vim.fs.dirname(file) .. "/" .. named)
    local target_stat, target_err, target_name = uv.fs_lstat(target)
    if target_stat then
        if target_stat.type == "link" then return nil, ("%s is a link to a link (%s)"):format(file, target) end
        return nil, ("something appeared at %s, which %s names, after it was read as absent"):format(target, file)
    end
    if target_name ~= "ENOENT" then
        return nil, ("%s, which %s names, could not be examined (%s)"):format(target, file, tostring(target_err))
    end
    return target
end

--- Nothing is at `file`: deal with a backup beside it, then create it exclusively
--- and write it, taking what was written away again if it did not all land (the
--- file that was created, never the symlink that names it).
---
--- A backup beside an absent cache is stale: it is what a deletion left, or what
--- was left when the cache was deleted by hand. It goes BEFORE the new cache is
--- created (unlinked, or if that fails emptied, whatever it holds), so that a
--- crash partway through creating the cache leaves a damaged cache next to no
--- backup, or an empty one, and recovery finds nothing from the deleted cache to
--- restore. A symlink or other non-regular file there is unlinked too, never
--- written through. If it can be neither removed nor emptied, or cannot even be
--- examined, nothing is created: it must be dealt with first.
local function write_new(file, bytes, parse)
    local bak = M.backup_path(file)
    local function refused(why)
        return false, ("could not write %s: %s; nothing was written"):format(file, why)
    end

    local state, detail = inspect_backup(bak, parse)
    if state == "unknown" then
        return refused(("its backup %s could not be examined (%s); that must be dealt with before this cache "
            .. "can be written"):format(bak, tostring(detail)))
    end
    local path, why = creation_target(file)
    if not path then return refused(("it could not be created: %s"):format(why)) end

    local note
    if state == "foreign" then
        local unlinked, err = uv.fs_unlink(bak)
        if not unlinked then
            return refused(("%s is not a regular file and could not be removed (%s); delete it before this cache "
                .. "can be written"):format(bak, tostring(err)))
        end
        note = foreign_note(bak, detail)
    elseif state ~= "absent" then
        local outcome, message = remove_backup(bak)
        if outcome == "failed" then
            return refused(("its stale backup %s %s; delete it by hand before this cache can be written"):format(
                bak, message))
        end
        if outcome == "emptied" then note = emptied_note(bak, message) end
    end

    -- A file that was created and then failed is already removed by write_file: the
    -- one that was created (a dangling link's target), never the link that names it.
    local ok, err = write_file(path, bytes, { create = true })
    if not ok then return false, err, note end
    return true, nil, note
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
    if state == "unknown" then
        return false, not_backed_up(file, ("%s could not be examined (%s), and may be the only good copy"):format(
            bak, tostring(kept)))
    end
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

--- A read found `file` present, read in full and empty or undecodable: if a good
--- copy is at the backup's name, write it back into the file, in place. The backup
--- is left where it is. Never over an absent file: see the header.
---@param file string
---@param parse fun(text: string): any? the data in `text`, nil when it is not usable
---@param main_stat table the descriptor's stat when `file` was read; nil (absent) recovers nothing
---@return any? recovered the data of the backup, nil when it was not used
---@return string? err why it could not be written back into `file`
function M.settle(file, parse, main_stat)
    local bak = M.backup_path(file)
    -- Not read in full from a regular file (absent, foreign, unreadable): it is
    -- unknown, so nothing is touched.
    if not main_stat then return nil end
    local state, text = read_backup(bak)
    if state ~= "read" then return nil end
    -- Only a backup that proves it is complete, and only its payload is written back.
    local payload = M.parse_backup(text)
    if not payload then return nil end
    local data = parse(payload)
    if data == nil then return nil end

    local restored, err = write_file(file, payload, { identity = main_stat })
    if restored then return data end
    return data, tostring(err)
end

return M
