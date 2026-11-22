-- Covers: write_json state by state: the cache (absent, good, damaged), its <path>.bak (absent, good, unreadable,
-- stale, symlink) and whether the cache can be backed up first.
local P = require("plenary.path")

local uv = vim.uv or vim.loop

local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
end

local function spit(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

--- A backup file holding `payload`, as the plugin writes one ...
local function put(path, payload)
    spit(path, require("codewars.cache.backup").frame_backup(payload))
end

--- ... and the payload of a backup file, nil if it is incomplete.
local function payload_of(path)
    return require("codewars.cache.backup").parse_backup(slurp(path))
end

local function perms(path)
    local stat = uv.fs_stat(path)
    return stat and bit.band(stat.mode, 511)
end

describe("cache.utils write_json, state by state", function()
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local cache_utils = require("codewars.cache.utils")
    local saved_storage, real_error, real_warn, real_write, real_open, errors, warnings
    local real_read, real_fstat, real_lstat, real_close
    local tmp, file, bak, original, good_bak, fresh, payload

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved_storage, real_error, real_warn = config.storage, log.error, log.warn
        real_write, real_open, errors, warnings = uv.fs_write, uv.fs_open, {}, {}
        real_read, real_fstat, real_lstat, real_close = uv.fs_read, uv.fs_fstat, uv.fs_lstat, uv.fs_close
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        log.error = function(msg) errors[#errors + 1] = tostring(msg) end
        log.warn = function(msg) warnings[#warnings + 1] = tostring(msg) end
        file, bak = tmp .. "/cache.json", tmp .. "/cache.json.bak"
        original = vim.json.encode({ old = string.rep("o", 300) })
        good_bak = vim.json.encode({ older = string.rep("b", 300) })
        fresh = { fresh = string.rep("n", 600) }
        payload = vim.json.encode(fresh)
    end)

    after_each(function()
        uv.fs_write, uv.fs_open, uv.fs_read = real_write, real_open, real_read
        uv.fs_fstat, uv.fs_lstat, uv.fs_close = real_fstat, real_lstat, real_close
        config.storage, log.error, log.warn = saved_storage, real_error, real_warn
        pcall(uv.fs_chmod, tmp, 493)
        pcall(uv.fs_chmod, file, 420)
        vim.fn.delete(tmp, "rf")
    end)

    local function write(opts) return cache_utils.write_json(P:new(file), fresh, opts) end

    --- A disk that fills up while `bytes` are being written: half of them land.
    --- Writes of anything in `also_failing` fail outright from then on.
    local function disk_full_on(bytes, also_failing)
        local failed = false
        uv.fs_write = function(fd, data, offset)
            if data == bytes then
                failed = true
                real_write(fd, data:sub(1, math.floor(#data / 2)), offset)
                return nil, "ENOSPC: no space left on device"
            end
            if failed and also_failing and vim.tbl_contains(also_failing, data) then
                return nil, "ENOSPC: no space left on device"
            end
            return real_write(fd, data, offset)
        end
    end

    --- Look at the filesystem at the moment the new bytes are written.
    local function look_during_write(look)
        local seen = {}
        uv.fs_write = function(fd, data, offset)
            if data == payload and seen.at == nil then seen.at = look() end
            return real_write(fd, data, offset)
        end
        return seen
    end

    local function cannot_write_dir()
        uv.fs_chmod(tmp, 365) -- 0555
        return not uv.fs_access(tmp, "W")
    end

    describe("a cache that cannot be backed up first", function()
        it("is not touched: a .bak that cannot be cleared away refuses the write", function()
            spit(file, original)
            vim.fn.mkdir(bak) -- a directory cannot be unlinked, and cannot be a backup

            local ok, err = write()

            assert.is_false(ok)
            assert.matches("back", err)
            assert.equals(original, slurp(file))
            assert.equals(1, #errors, vim.inspect(errors))
        end)

        it("is not touched: a disk that fills while backing up refuses the write", function()
            spit(file, original)
            local before = uv.fs_stat(file)
            disk_full_on(require("codewars.cache.backup").frame_backup(original)) -- only the backup copy writes it

            local ok, err = write()

            assert.is_false(ok)
            assert.matches("ENOSPC", err)
            assert.equals(original, slurp(file), "the cache was written without a backup")
            assert.equals(before.mtime.nsec, uv.fs_stat(file).mtime.nsec)
            assert.is_nil(uv.fs_stat(bak), "a half-written backup was left behind")
            assert.equals(1, #errors, vim.inspect(errors))
        end)

        it("is not touched: a directory that cannot be written refuses the write", function()
            spit(file, original)
            if not cannot_write_dir() then return pending("running as a user that ignores directory modes") end

            local ok, err = write()

            assert.is_false(ok)
            assert.is_string(err)
            assert.equals(original, slurp(file))
            assert.equals(1, #errors, vim.inspect(errors))
        end)

        it("is not touched: a cache that cannot be read to back it up refuses the write", function()
            spit(file, original)
            uv.fs_chmod(file, 128) -- 0200: writable, not readable
            if uv.fs_access(file, "R") then return pending("running as a user that ignores file modes") end

            local ok = write()

            assert.is_false(ok)
            uv.fs_chmod(file, 420)
            assert.equals(original, slurp(file))
            assert.is_nil(uv.fs_stat(bak))
        end)

        it("says nothing when the write is quiet", function()
            spit(file, original)
            vim.fn.mkdir(bak)

            local ok = write({ quiet = true })

            assert.is_false(ok)
            assert.same({}, errors)
            assert.same({}, warnings)
        end)

        it("is not an obstacle to a new file, which has nothing to back up", function()
            assert.is_true((write()))
            assert.same(fresh, vim.json.decode(slurp(file)))
        end)
    end)

    describe("a .bak that holds a good copy", function()
        for _, damaged in ipairs({ "{ torn", "" }) do
            local what = damaged == "" and "empty" or "undecodable"

            it(("is not overwritten by a cache that is %s, and goes once the write lands"):format(what), function()
                spit(file, damaged)
                put(bak, good_bak)
                local seen = look_during_write(function() return payload_of(bak) end)

                assert.is_true((write()))

                assert.equals(good_bak, seen.at, "the good copy was replaced by the damaged cache")
                assert.same(fresh, vim.json.decode(slurp(file)))
                assert.is_nil(uv.fs_stat(bak))
            end)

            it(("is written back over a cache that is %s when the write fails, then goes"):format(what), function()
                spit(file, damaged)
                put(bak, good_bak)
                disk_full_on(payload)

                local ok = write()

                assert.is_false(ok)
                assert.equals(good_bak, slurp(file))
                assert.is_nil(uv.fs_stat(bak))
            end)

            it(("is kept when it cannot be written back over a cache that is %s"):format(what), function()
                spit(file, damaged)
                put(bak, good_bak)
                disk_full_on(payload, { good_bak })

                local ok, err = write()

                assert.is_false(ok)
                assert.matches(vim.pesc(bak), err)
                assert.equals(good_bak, payload_of(bak))
            end)
        end

        it("is kept when the write is refused before anything changed", function()
            spit(file, "{ torn")
            put(bak, good_bak)
            uv.fs_chmod(file, 256) -- 0400
            if uv.fs_access(file, "W") then return pending("running as a user that ignores file modes") end

            local ok = write()

            assert.is_false(ok)
            assert.equals("{ torn", slurp(file))
            assert.equals(good_bak, payload_of(bak), "the good copy was removed though the cache was never written")
        end)

        -- An absent cache was deleted: its stale backup goes BEFORE the new cache is created, so a crash
        -- partway through leaves nothing to recover.
        it("is gone before a cache that is not there is created", function()
            put(bak, good_bak)
            local seen = look_during_write(function() return uv.fs_lstat(bak) == nil and "gone" or "still there" end)

            assert.is_true((write()))

            assert.equals("gone", seen.at)
            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.is_nil(uv.fs_stat(bak))
        end)

        it("is gone when the new cache fails, which is removed too", function()
            put(bak, good_bak)
            disk_full_on(payload)

            local ok = write()

            assert.is_false(ok)
            assert.is_nil(uv.fs_stat(file))
            assert.is_nil(uv.fs_stat(bak))
        end)

        it("is used as it is when the directory cannot be written, and emptied since it cannot be removed", function()
            spit(file, "{ torn")
            put(bak, good_bak)
            if not cannot_write_dir() then return pending("running as a user that ignores directory modes") end

            local ok = write()

            assert.is_true(ok)
            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.equals(0, uv.fs_stat(bak).size, "a backup that cannot be removed was left to be recovered from")
            assert.same(fresh, cache_utils.read_json(P:new(file)))
        end)

        it("is not touched by the retry that follows a recovery that could not be written back", function()
            spit(file, "{ torn")
            put(bak, good_bak)
            -- 1. the read finds the damage and the backup, and the disk is full
            disk_full_on(good_bak)
            assert.same({ older = string.rep("b", 300) }, cache_utils.read_json(P:new(file)))
            -- 2. a write over the damaged cache fails too, and cannot restore either
            uv.fs_write = real_write
            disk_full_on(payload, { good_bak })

            local ok = write({ quiet = true })

            assert.is_false(ok)
            assert.equals(good_bak, payload_of(bak), "the good copy was overwritten with the damaged cache")
            -- 3. once there is room the next read recovers it
            uv.fs_write = real_write
            assert.same({ older = string.rep("b", 300) }, cache_utils.read_json(P:new(file)))
            assert.equals(good_bak, slurp(file))
        end)
    end)

    describe("a cache that is damaged, with no .bak", function()
        it("is backed up as it is and put back as it was when the write fails", function()
            spit(file, "{ torn")
            local backed_up
            uv.fs_write = function(fd, data, offset)
                if data ~= payload then return real_write(fd, data, offset) end
                backed_up = payload_of(bak)
                real_write(fd, data:sub(1, 100), offset)
                return nil, "ENOSPC: no space left on device"
            end

            local ok = write()

            assert.is_false(ok)
            assert.equals("{ torn", backed_up)
            assert.equals("{ torn", slurp(file))
            assert.is_nil(uv.fs_stat(bak))
        end)
    end)

    --- Whether an open is for writing (by name, or by the flag bits), or for reading.
    local C = uv.constants or {}
    local WRITE_BITS = bit.bor(C.O_WRONLY or 0, C.O_RDWR or 0, C.O_CREAT or 0)
    local function is_write_open(flags)
        return flags == "w" or flags == "wx" or flags == "r+"
            or (type(flags) == "number" and bit.band(flags, WRITE_BITS) ~= 0)
    end
    local function is_read_open(flags) return not is_write_open(flags) end

    --- Reads of the backup fail the way a permission or an I/O error would:
    --- the open itself ("open"), or a read after a good open ("read").
    local function bak_unreadable(how)
        local fds = {}
        uv.fs_close = function(fd)
            fds[fd] = nil -- descriptor numbers are reused
            return real_close(fd)
        end
        uv.fs_open = function(path, flags, mode)
            if path ~= bak or not is_read_open(flags) then return real_open(path, flags, mode) end
            if how == "open" then return nil, "EACCES: permission denied: " .. bak, "EACCES" end
            local fd, err, name = real_open(path, flags, mode)
            if fd then fds[fd] = true end
            return fd, err, name
        end
        uv.fs_read = function(fd, size, offset)
            if fds[fd] then return nil, "EIO: i/o error" end
            return real_read(fd, size, offset)
        end
    end

    describe("a .bak that cannot be read", function()
        -- Unknown, not junk: it may be the one good copy. Only a .bak read in full that does not decode,
        -- one beside a cache that decodes, or a non-regular file may be removed or replaced.
        for _, how in ipairs({ "open", "read", "mode" }) do
            it(("refuses the write over a damaged cache, touching neither file (%s error)"):format(how), function()
                spit(file, "{ torn")
                put(bak, good_bak)
                local before = uv.fs_stat(file)
                if how == "mode" then
                    uv.fs_chmod(bak, 0)
                    if uv.fs_access(bak, "R") then return pending("running as a user that ignores file modes") end
                else
                    bak_unreadable(how)
                end

                local ok, err = write()

                uv.fs_open, uv.fs_read = real_open, real_read
                uv.fs_chmod(bak, 420)
                assert.is_false(ok)
                assert.matches(vim.pesc(bak), err)
                assert.equals("{ torn", slurp(file))
                assert.equals(before.mtime.nsec, uv.fs_stat(file).mtime.nsec)
                assert.equals(good_bak, payload_of(bak), "a backup that could not be read was replaced")
                assert.equals(1, #errors, vim.inspect(errors))
            end)
        end

        it("refuses it over an empty cache as well, and says nothing when quiet", function()
            spit(file, "")
            put(bak, good_bak)
            bak_unreadable("open")

            local ok, err = write({ quiet = true })

            uv.fs_open = real_open
            assert.is_false(ok)
            assert.matches(vim.pesc(bak), err)
            assert.equals("", slurp(file))
            assert.equals(good_bak, payload_of(bak))
            assert.same({}, errors)
        end)

        it("is stale beside a cache that decodes, so it is replaced and the write goes ahead", function()
            spit(file, original)
            put(bak, good_bak)
            bak_unreadable("open")

            local ok = write()

            uv.fs_open = real_open
            assert.is_true(ok)
            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.is_nil(uv.fs_lstat(bak))
        end)

        it("is removed once a new file has landed beside it: it is stale then, and may not stay unread", function()
            put(bak, good_bak)
            bak_unreadable("open")

            local ok = write()

            uv.fs_open = real_open
            assert.is_true(ok)
            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.is_nil(uv.fs_lstat(bak))
        end)
    end)

    describe("a .bak swapped under the open", function()
        --- Run Lua in a fresh Neovim that must finish before `ms`: a blocking open would hang it, so fail instead.
        local function in_child(body, ms)
            local script = tmp .. "/child.lua"
            spit(script, ("vim.opt.rtp:prepend(%s)\n%s"):format(vim.inspect(vim.fn.getcwd()), body))
            local res = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-c", "luafile " .. script,
                "-c", "qa!" }, { timeout = ms, text = true }):wait()
            return { done = res.code ~= 124 and res.signal == 0, text = (res.stdout or "") .. (res.stderr or "") }
        end

        local function can_run_child()
            return vim.system ~= nil and vim.fn.executable("mkfifo") == 1
        end

        local function fifo_at(path)
            vim.fn.system({ "mkfifo", path })
            return vim.v.shell_error == 0
        end

        --- lstat says "a regular file" for `bak`, as it did before the swap; the open meets a pipe.
        local function child_body(main_text)
            return ([[
local uv = vim.uv or vim.loop
local backup = require("codewars.cache.backup")
local real_lstat = uv.fs_lstat
uv.fs_lstat = function(p, ...)
    local st = real_lstat(p, ...)
    if p == %s and st then st.type = "file" end
    return st
end
local function parse(t) local ok, d = pcall(vim.json.decode, t); return ok and d or nil end
local f = assert(io.open(%s, "wb")); f:write(%s); f:close()
local ok, err = backup.write(%s, "{}", parse)
print("RESULT", tostring(ok), tostring(err))
]]):format(vim.inspect(bak), vim.inspect(file), vim.inspect(main_text), vim.inspect(file))
        end

        it("does not block: the pipe is opened without waiting and refused before a byte is read", function()
            if not can_run_child() then return pending("needs vim.system (Neovim 0.10) and mkfifo") end
            assert(fifo_at(bak))

            local res = in_child(child_body("{ torn"), 5000)

            assert.is_true(res.done, "the open of the pipe blocked: " .. res.text)
            assert.matches("RESULT%s+false", res.text)
            assert.matches("could not be read", res.text)
            assert.equals("{ torn", slurp(file))
        end)

        it("is replaced when the cache beside it decodes", function()
            if not can_run_child() then return pending("needs vim.system (Neovim 0.10) and mkfifo") end
            assert(fifo_at(bak))

            local res = in_child(child_body(original), 5000)

            assert.is_true(res.done, "the open of the pipe blocked: " .. res.text)
            assert.matches("RESULT%s+true", res.text)
        end)

        it("is never opened when it is a pipe from the start", function()
            if not can_run_child() then return pending("needs vim.system (Neovim 0.10) and mkfifo") end
            assert(fifo_at(bak))
            local body = ([[
local backup = require("codewars.cache.backup")
local function parse(t) local ok, d = pcall(vim.json.decode, t); return ok and d or nil end
local f = assert(io.open(%s, "wb")); f:write(%s); f:close()
print("RESULT", tostring((backup.write(%s, "{}", parse))))
]]):format(vim.inspect(file), vim.inspect(original), vim.inspect(file))

            local res = in_child(body, 5000)

            assert.is_true(res.done, "something opened the pipe: " .. res.text)
            assert.matches("RESULT%s+true", res.text)
        end)

        it("opens everything it reads without blocking, so a pipe cannot hang it", function()
            local nonblock = uv.constants and uv.constants.O_NONBLOCK
            if not nonblock then return pending("this luv does not expose O_NONBLOCK") end
            spit(file, original)
            put(bak, good_bak)
            local reads = {}
            uv.fs_open = function(path, flags, mode)
                if is_read_open(flags) then reads[path] = flags end
                return real_open(path, flags, mode)
            end

            assert.is_true((write()))
            spit(file, "{ torn")
            put(bak, good_bak)
            cache_utils.read_json(P:new(file))

            for _, path in ipairs({ file, bak }) do
                assert.equals("number", type(reads[path]), path .. " was opened by name, which can block on a pipe")
                assert.is_true(bit.band(reads[path], nonblock) ~= 0, path .. " was opened without O_NONBLOCK")
            end
        end)

        --- Make the descriptor of the backup say something else than the lstat did.
        local function fstat_says(change)
            local fds = {}
            uv.fs_close = function(fd)
                fds[fd] = nil -- descriptor numbers are reused
                return real_close(fd)
            end
            uv.fs_open = function(path, flags, mode)
                local fd, err = real_open(path, flags, mode)
                if fd and path == bak and is_read_open(flags) then fds[fd] = true end
                return fd, err
            end
            uv.fs_fstat = function(fd)
                local st = real_fstat(fd)
                if st and fds[fd] then change(st) end
                return st
            end
            local read_any = false
            uv.fs_read = function(fd, size, offset)
                if fds[fd] then read_any = true end
                return real_read(fd, size, offset)
            end
            return function() return read_any end
        end

        for name, change in pairs({
            ["is not a regular file"] = function(st) st.type = "fifo" end,
            ["is another file than the one that was checked"] = function(st) st.ino = st.ino + 1 end,
            ["is on another device than the one that was checked"] = function(st) st.dev = st.dev + 1 end,
        }) do
            it(("is refused before a byte is read when the opened descriptor %s"):format(name), function()
                spit(file, "{ torn")
                put(bak, good_bak)
                local read_any = fstat_says(change)

                local ok, err = write()

                uv.fs_open, uv.fs_fstat, uv.fs_read = real_open, real_fstat, real_read
                assert.is_false(read_any(), "a byte was read from a file that failed the check")
                assert.is_false(ok)
                assert.matches(vim.pesc(bak), err)
                assert.equals("{ torn", slurp(file))
                assert.equals(good_bak, payload_of(bak))
            end)
        end
    end)

    describe("a .bak that is stale or no use", function()
        it("is replaced by a fresh backup when the cache decodes", function()
            spit(file, original)
            put(bak, good_bak)
            local seen = look_during_write(function() return payload_of(bak) end)

            assert.is_true((write()))

            assert.equals(original, seen.at, "the stale backup was not replaced")
            assert.is_nil(uv.fs_stat(bak))
        end)

        it("is replaced by a fresh backup of what is there when nothing decodes", function()
            spit(file, "{ torn")
            put(bak, "{ also torn")
            local seen = look_during_write(function() return payload_of(bak) end)

            assert.is_true((write()))

            assert.equals("{ torn", seen.at)
            assert.is_nil(uv.fs_stat(bak))
        end)

        it("is replaced by a fresh backup when it is undecodable and the cache decodes", function()
            spit(file, original)
            put(bak, "{ torn")
            disk_full_on(payload)

            local ok = write()

            assert.is_false(ok)
            assert.equals(original, slurp(file))
            assert.is_nil(uv.fs_stat(bak))
        end)
    end)

    describe("a .bak that is a symlink", function()
        local target

        before_each(function()
            target = tmp .. "/precious.txt"
            spit(target, "do not touch")
            uv.fs_chmod(target, 416) -- 0640
        end)

        local function untouched()
            assert.equals("do not touch", slurp(target), "the symlink was followed and its target overwritten")
            assert.equals(416, perms(target), "the symlink was followed and its target's mode changed")
        end

        it("is unlinked, not followed: its target is untouched and the backup is a real file", function()
            spit(file, original)
            uv.fs_symlink(target, bak)
            local seen = look_during_write(function()
                return { kind = uv.fs_lstat(bak).type, text = payload_of(bak) }
            end)

            assert.is_true((write()))

            assert.equals("file", seen.at.kind)
            assert.equals(original, seen.at.text)
            untouched()
            assert.is_nil(uv.fs_lstat(bak), "the link or the backup was left behind")
            assert.same(fresh, vim.json.decode(slurp(file)))
        end)

        it("is unlinked even when it points at nothing", function()
            spit(file, original)
            uv.fs_symlink(tmp .. "/nowhere", bak)

            assert.is_true((write()))

            assert.is_nil(uv.fs_lstat(bak))
            assert.is_nil(uv.fs_stat(tmp .. "/nowhere"), "the dangling link was followed and its target created")
        end)

        it("is unlinked when the cache is damaged too, since a link is no good copy", function()
            spit(file, "{ torn")
            put(target, good_bak)
            uv.fs_symlink(target, bak)

            assert.is_true((write()))

            assert.equals(good_bak, payload_of(target))
            assert.is_nil(uv.fs_lstat(bak))
        end)

        it("is unlinked, not followed, before a new cache is created beside it", function()
            uv.fs_symlink(target, bak)

            assert.is_true((write()))

            assert.same(fresh, vim.json.decode(slurp(file)))
            untouched()
            assert.is_nil(uv.fs_lstat(bak), "the link was left in place")
        end)

        it("is said so once, and not at all when the write is quiet", function()
            spit(file, original)
            uv.fs_symlink(target, bak)
            assert.is_true((write()))
            uv.fs_symlink(target, bak)
            assert.is_true((write()))
            assert.equals(1, #warnings, vim.inspect(warnings))

            warnings = {}
            spit(tmp .. "/other.json", original)
            uv.fs_symlink(target, tmp .. "/other.json.bak")
            assert.is_true((cache_utils.write_json(P:new(tmp .. "/other.json"), fresh, { quiet = true })))
            assert.same({}, warnings)
        end)

        it("planted between the check and the create is not followed either", function()
            spit(file, original)
            uv.fs_open = function(path, flags, mode)
                if path == bak and is_write_open(flags) then uv.fs_symlink(target, bak) end
                return real_open(path, flags, mode)
            end

            local ok = write()

            assert.is_false(ok)
            assert.equals(original, slurp(file))
            untouched()
        end)
    end)

    describe("quiet", function()
        it("logs nothing over a damaged cache and a good backup, written or not", function()
            spit(file, "{ torn")
            put(bak, good_bak)
            disk_full_on(payload)
            assert.is_false((write({ quiet = true })))
            assert.same({}, errors)
            assert.same({}, warnings)

            uv.fs_write = real_write
            spit(file, "{ torn")
            put(bak, good_bak)
            assert.is_true((write({ quiet = true })))
            assert.same({}, errors)
            assert.same({}, warnings)
        end)

        it("still reports a failure to the caller", function()
            spit(file, original)
            disk_full_on(payload)

            local ok, err = write({ quiet = true })

            assert.is_false(ok)
            assert.matches("ENOSPC", err)
        end)
    end)
end)
