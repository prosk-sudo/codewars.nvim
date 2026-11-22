--- Writes a cache file in place, keeping a copy of the old bytes at <file>.bak (Vim's
--- `backupcopy=yes`): restored if the write fails, dropped once it lands. No backup, no write.
---
--- Rules:
---  * Recover only a cache that is present and empty or undecodable.
---  * Never recover an absent or unreadable cache: that is unknown, not damaged.
---  * A backup is trusted only if its `CWBAK1 <length> <sha256>` header matches.
---  * A stale backup is discarded before a new cache is created.
---  * Every open is non-blocking and fstat-checked.
---  * A created file that fails is emptied and removed.
---
--- Threat model: protects against failed or partial writes, crashes, transient read
--- errors and stale backups. Assumes the cache directory is the user's own. Out of
--- scope: a concurrent process racing in that directory, shared sticky directories,
--- and two Neovim instances on one cache.
local uv = vim.uv or vim.loop

local M = {}

local SUFFIX = ".bak"
local DEFAULT_MODE = 438 -- 0666: what a new file is created with, before the umask trims it
local PERMISSION_BITS = 511 -- 0777
local READ_CHUNK = 65536

-- O_NONBLOCK keeps an open from hanging on a file swapped for a pipe. O_NOFOLLOW is used only where luv has it;
-- without `constants` files open by name ("r", "wx"), which can block but has the same checks.
local constants = uv.constants or {}
local READ_FLAGS = bit.bor(constants.O_RDONLY or 0, constants.O_NONBLOCK or 0)
local READ_BACKUP_FLAGS = bit.bor(READ_FLAGS, constants.O_NOFOLLOW or 0)

--- Flags to open for writing without truncating; `create` opens exclusively.
---@param create boolean? create it exclusively: it is ours once the open succeeds
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

--- The payload of a backup whose header, length and checksum all match; nil otherwise.
--- Whether the payload decodes is a separate check.
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

--- Whether a directory entry is a cache backup; scans skip these.
---@param name string
---@return boolean
function M.is_backup(name)
    return name:sub(-#SUFFIX) == SUFFIX
end

--- Whether `path` is rooted: a leading "/", or on Windows a drive or UNC prefix.
--- (vim.fn.isabsolutepath is missing on Neovim 0.9 and 0.10.)
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

--- Whether anything is at the backup's name, a dangling symlink included. Any lstat
--- error reads as "no": a backup that cannot be examined recovers nothing.
---@param file string
---@return boolean
function M.has_backup(file)
    return uv.fs_lstat(M.backup_path(file)) ~= nil
end

--- Write all of `data` to `fd`, continuing after short writes; no progress is a failure.
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
---@field exact boolean? also fchmod to exactly `mode`, past the umask
---@field create boolean? create exclusively (O_CREAT|O_EXCL): once opened it is ours
---@field identity table? stat the descriptor must match (inode and device)

--- Opens `path` without blocking or truncating, checks the descriptor, then truncates, writes, fsyncs and closes.
--- A file that `create` made is emptied, then unlinked, if anything fails; a pre-existing file is never unlinked.
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

    -- Failed and ours: empty it while it is still open.
    local emptied
    if not ok and opts.create and touched then
        emptied = uv.fs_ftruncate(fd, 0) and uv.fs_fsync(fd) or false
    end
    local closed, close_err = uv.fs_close(fd)
    if ok and not closed then ok, err = false, close_err end
    if not ok and opts.create then
        local removed, unlink_err, name = uv.fs_unlink(path)
        if not removed and name ~= "ENOENT" then
            -- Not emptied via the descriptor: empty it by path, if it is still the file that was created.
            if touched and not emptied then emptied = write_file(path, "", { identity = stat }) end
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

--- The bytes of a regular file. The descriptor is checked, and matched to `expect` if given, before any read.
---@param path string
---@param expect table? uv stat of `path` taken just before; the open also refuses a symlink where it can
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

--- The cache file as a read finds it: "absent" (ENOENT or a dangling link), "read" (a regular file read in full;
--- `detail` its bytes, `stat` its descriptor's) or "unreadable" (`detail` says why): unknown, never written over.
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

--- What is at the backup's name, by lstat (never through a symlink); `detail` is the bytes for "read", else why.
--- "unknown" (lstat failed) and "unreadable" (not read in full) may hide the one good copy, so they are not junk.
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

--- `read_backup`, with a file read in full sorted into "good" (a complete backup whose payload decodes;
--- `detail` is the payload) or "unusable".
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

--- Copy `original` to a fresh backup with its permission bits (a 0600 cache must not leak into a 0644 copy).
--- Whatever is at the name is unlinked first and the copy created exclusively, so a planted symlink is never followed.
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

--- Unlink a backup that must not be recovered from again; if that fails, empty it (an empty file never decodes).
--- Only ENOENT means gone; one that cannot be examined is neither emptied (no identity to check) nor called removed.
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

--- The write landed, so the backup is stale: remove it, or a later damaged cache would "recover" the old contents.
---@param bak string
---@return boolean ok
---@return string? message a note when it had to be emptied, why it could not be when not ok
local function discard_backup(bak)
    local outcome, detail = remove_backup(bak)
    if outcome == "gone" then return true end
    if outcome == "emptied" then return true, emptied_note(bak, detail) end
    return false, ("the new data was written, but a stale backup at %s %s; delete it by hand"):format(bak, detail)
end

--- Remove the backup of a cache being deleted, so the next read does not "recover" it. Unlinks (a symlink goes,
--- its target stays), else empties; `false` only if both fail.
---@param path Path|string
---@return boolean ok
---@return string? why when not ok, a sentence naming the backup
function M.drop(path)
    local bak = M.backup_path(M.file_name(path))
    local outcome, detail = remove_backup(bak)
    if outcome == "failed" then return false, ("the backup at %s %s"):format(bak, detail) end
    return true
end

--- `drop` for a deletion the user asked for: it goes on regardless, and a backup left behind is warned about.
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

--- Where an absent cache is created: the path itself, or for a dangling symlink the path it names (one level,
--- never through the link). A link to a link, or anything that appeared or cannot be examined, is refused.
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

--- Nothing is at `file`: the backup beside it is stale and goes first (unlinked, else emptied; if neither, refuse),
--- so a crash while creating leaves nothing to recover. Then the cache is created exclusively.
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

    -- write_file removes a created file that failed: a dangling link's target, never the link.
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

--- `file` exists and was read as `original` (stat `identity`): back it up, write in place, restore on failure.
local function write_over(file, bytes, original, identity, parse)
    local bak = M.backup_path(file)
    local function decodes() return parse(original) ~= nil end

    -- An unreadable copy is unknown, not junk: beside a bad cache it may be the one good copy, so touch nothing.
    local state, kept = inspect_backup(bak, parse)
    if state == "unknown" then
        return false, not_backed_up(file, ("%s could not be examined (%s), and may be the only good copy"):format(
            bak, tostring(kept)))
    end
    if state == "unreadable" and not decodes() then
        return false, not_backed_up(file, ("%s could not be read (%s), and may be the only good copy"):format(
            bak, tostring(kept)))
    end

    -- A good copy beside a cache that does not decode IS the backup: keep it, restore from it,
    -- and remove it only once the new bytes land. Anything else there is replaced.
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
        -- Refused before anything changed, so nothing to put back. Our own copy goes; a good one left earlier stays.
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
    -- Not known to be damaged, so not written over without a backup.
    if state == "unreadable" then return false, not_backed_up(file, "it could not be read: " .. detail) end
    return write_over(file, bytes, detail, stat, parse)
end

--- `file` was read in full and is empty or undecodable: write a good backup's payload back in place.
--- The backup stays (only a writer removes one). Never recovers an absent file.
---@param file string
---@param parse fun(text: string): any? the data in `text`, nil when it is not usable
---@param main_stat table the descriptor's stat when `file` was read; nil (absent) recovers nothing
---@return any? recovered the data of the backup, nil when it was not used
---@return string? err why it could not be written back into `file`
function M.settle(file, parse, main_stat)
    local bak = M.backup_path(file)
    -- Not read in full from a regular file (absent, foreign, unreadable): unknown, so nothing is touched.
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
