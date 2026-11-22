-- The edges of the in-place cache writer that are plain bugs, not attacks:
--   * a cache that is absent is created exclusively (O_CREAT|O_EXCL), never
--     through whatever appears at its path after it was read; a dangling
--     symlink that is the configured cache is resolved one level and its
--     target is created, and a failed write removes that target, never the link
--   * only ENOENT means a backup is absent; any other error looking at it is
--     "unknown" and refuses a write, and a read recovers nothing
--   * deleting a cache gets rid of its backup (unlink, else empty it), and says so
--     when it can do neither; and since an absent cache is never recovered, a
--     backup that could not be removed brings nothing back
--   * a symlink's target is resolved without vim.fn.isabsolutepath, which Neovim 0.9
--     and 0.10 do not have
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

describe("cache.backup, absent caches, unknown backups and deletions", function()
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local cache_utils = require("codewars.cache.utils")
    local backup = require("codewars.cache.backup")
    local saved_storage, real_error, real_warn, errors, warnings
    local real_open, real_lstat, real_unlink, real_write
    local tmp, file, bak, precious, older, fresh, payload

    local C = uv.constants or {}
    local WRITE_BITS = bit.bor(C.O_WRONLY or 0, C.O_RDWR or 0, C.O_CREAT or 0)
    local function is_write_open(flags)
        return flags == "w" or flags == "wx" or flags == "r+"
            or (type(flags) == "number" and bit.band(flags, WRITE_BITS) ~= 0)
    end

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved_storage, real_error, real_warn, errors, warnings = config.storage, log.error, log.warn, {}, {}
        real_open, real_lstat, real_unlink, real_write = uv.fs_open, uv.fs_lstat, uv.fs_unlink, uv.fs_write
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        log.error = function(msg) errors[#errors + 1] = tostring(msg) end
        log.warn = function(msg) warnings[#warnings + 1] = tostring(msg) end
        file, bak = tmp .. "/cache.json", tmp .. "/cache.json.bak"
        precious = tmp .. "/precious.txt"
        spit(precious, "do not touch")
        uv.fs_chmod(precious, 416) -- 0640
        older = vim.json.encode({ older = string.rep("o", 300) })
        fresh = { fresh = string.rep("f", 600) }
        payload = vim.json.encode(fresh)
        -- Not in Neovim 0.9 or 0.10: nothing here may call it.
        vim.fn.isabsolutepath = function() error("E117: Unknown function: isabsolutepath") end
    end)

    after_each(function()
        vim.fn.isabsolutepath = nil
        uv.fs_open, uv.fs_lstat, uv.fs_unlink, uv.fs_write = real_open, real_lstat, real_unlink, real_write
        config.storage, log.error, log.warn = saved_storage, real_error, real_warn
        pcall(uv.fs_chmod, file, 420)
        vim.fn.delete(tmp, "rf")
    end)

    local function write(opts) return cache_utils.write_json(P:new(file), fresh, opts) end
    local function read() return cache_utils.read_json(P:new(file)) end

    local function precious_untouched()
        assert.equals("do not touch", slurp(precious), "a file that was not the cache was written through a link")
        assert.equals(416, bit.band(uv.fs_stat(precious).mode, 511))
    end

    --- A disk that fills up while `bytes` are being written: half of them land.
    local function disk_full_on(bytes)
        uv.fs_write = function(fd, data, offset)
            if data == bytes then
                real_write(fd, data:sub(1, math.floor(#data / 2)), offset)
                return nil, "ENOSPC: no space left on device"
            end
            return real_write(fd, data, offset)
        end
    end

    --- Plant a symlink at `file` to `precious` after the cache was read as absent
    --- ("read"), or just as it is opened for writing ("write").
    local function plant_link(when)
        local planted = false
        uv.fs_open = function(path, flags, mode)
            if path ~= file then return real_open(path, flags, mode) end
            if when == "write" then
                if is_write_open(flags) and not uv.fs_lstat(file) then uv.fs_symlink(precious, file) end
                return real_open(path, flags, mode)
            end
            local fd, err, name = real_open(path, flags, mode)
            if not fd and name == "ENOENT" and not is_write_open(flags) and not planted then
                planted = true
                uv.fs_symlink(precious, file)
            end
            return fd, err, name
        end
    end

    describe("an absent cache", function()
        for _, when in ipairs({ "read", "write" }) do
            it(("is not created through a symlink to another file planted after the read (%s)"):format(when), function()
                plant_link(when)

                local ok, err = write()

                uv.fs_open = real_open
                assert.is_false(ok)
                assert.is_string(err)
                precious_untouched()
                assert.equals(1, #errors, vim.inspect(errors))
            end)
        end

        it("is created at the target of a dangling symlink that is the configured cache, leaving the link", function()
            local target = tmp .. "/real-cache.json"
            uv.fs_symlink(target, file)

            local ok, err = write()

            assert.is_true(ok, tostring(err))
            assert.equals(payload, slurp(target))
            assert.equals("link", uv.fs_lstat(file).type)
            assert.equals(target, uv.fs_readlink(file))
        end)

        it("is created at a relative target of a dangling symlink, resolved against the link's directory", function()
            uv.fs_symlink("real-cache.json", file)

            assert.is_true((write()))

            assert.equals(payload, slurp(tmp .. "/real-cache.json"))
            assert.equals("link", uv.fs_lstat(file).type)
            assert.equals("real-cache.json", uv.fs_readlink(file))
        end)

        it("is refused when the link points at another link", function()
            local middle = tmp .. "/middle.json"
            uv.fs_symlink(tmp .. "/nowhere.json", middle)
            uv.fs_symlink(middle, file)

            local ok, err = write()

            assert.is_false(ok)
            assert.matches("link", err)
            assert.is_nil(uv.fs_lstat(tmp .. "/nowhere.json"), "a file was created through two links")
            assert.equals("link", uv.fs_lstat(middle).type)
            assert.equals("link", uv.fs_lstat(file).type)
        end)

        it("is not recovered, even through a dangling link: nothing is created from a leftover backup", function()
            local target = tmp .. "/real-cache.json"
            uv.fs_symlink(target, file)
            spit(bak, older)

            assert.is_nil(read())

            assert.is_nil(uv.fs_lstat(target))
            assert.equals("link", uv.fs_lstat(file).type)
        end)

        it("leaves a dangling link intact and no partial target when the write fails halfway", function()
            local target = tmp .. "/real-cache.json"
            uv.fs_symlink(target, file)
            disk_full_on(payload)

            local ok, err = write()

            assert.is_false(ok)
            assert.matches("ENOSPC", err)
            assert.equals("link", uv.fs_lstat(file).type, "the configured symlink was removed")
            assert.equals(target, uv.fs_readlink(file))
            assert.is_nil(uv.fs_lstat(target), "a partial target was left behind")
            assert.equals(1, #errors, vim.inspect(errors))
        end)

        it("leaves no partial file when a plain new cache fails halfway", function()
            disk_full_on(payload)

            assert.is_false((write()))

            assert.is_nil(uv.fs_lstat(file))
        end)
    end)

    describe("a link target that is absolute or relative", function()
        local function with_win32(on, body)
            local real_has = vim.fn.has
            vim.fn.has = function(what)
                if what == "win32" then return on and 1 or 0 end
                return real_has(what)
            end
            local ok, err = pcall(body)
            vim.fn.has = real_has
            assert(ok, err)
        end

        it("is told by its first character where the path is rooted", function()
            assert.is_true(backup.is_absolute("/var/cache/codewars.json"))
            assert.is_false(backup.is_absolute("cache/codewars.json"))
            assert.is_false(backup.is_absolute("../codewars.json"))
            assert.is_false(backup.is_absolute(""))
        end)

        it("is not made absolute by a drive prefix or a UNC name except on Windows", function()
            with_win32(false, function()
                assert.is_false(backup.is_absolute("C:\\caches\\codewars.json"))
                assert.is_false(backup.is_absolute("\\\\host\\share\\codewars.json"))
            end)
        end)

        it("is made absolute by a drive prefix or a UNC name on Windows", function()
            with_win32(true, function()
                assert.is_true(backup.is_absolute("C:\\caches\\codewars.json"))
                assert.is_true(backup.is_absolute("c:/caches/codewars.json"))
                assert.is_true(backup.is_absolute("\\\\host\\share\\codewars.json"))
                assert.is_true(backup.is_absolute("//host/share/codewars.json"))
                assert.is_false(backup.is_absolute("caches\\codewars.json"))
            end)
        end)
    end)

    describe("a new cache beside a stale backup", function()
        -- The backup goes first. A crash partway through creating the cache then leaves a
        -- damaged cache next to no backup (or an empty one): nothing to recover the
        -- deleted data from.
        local function unlink_fails()
            uv.fs_unlink = function(path)
                if path == bak then return nil, "EPERM: operation not permitted: " .. path, "EPERM" end
                return real_unlink(path)
            end
        end

        --- ...and the backup cannot be emptied either: the one open for writing it is not the create.
        local function empty_fails()
            uv.fs_open = function(path, flags, mode)
                if path == bak and is_write_open(flags) then
                    return nil, "EACCES: permission denied: " .. path, "EACCES"
                end
                return real_open(path, flags, mode)
            end
        end

        --- A crash right after the file is created: the write fails, and the clean-up
        --- that would remove the half-written file never runs.
        local function crash_after_create()
            uv.fs_write = function(fd, data, offset)
                if data == payload then
                    real_write(fd, data:sub(1, 100), offset)
                    return nil, "ENOSPC: no space left on device"
                end
                return real_write(fd, data, offset)
            end
            local unlink = uv.fs_unlink
            uv.fs_unlink = function(path)
                if path == file then return true end -- the clean-up that a crash does not do
                return unlink(path)
            end
        end

        it("leaves nothing to recover after a crash partway through creating it", function()
            spit(bak, older)
            crash_after_create()

            assert.is_false((write({ quiet = true })))

            uv.fs_unlink, uv.fs_write = real_unlink, real_write
            assert.is_not_nil(uv.fs_lstat(file), "the crash left no half-written cache, so the test proves nothing")
            assert.is_nil(read(), "a damaged cache was restored from the backup of a deleted one")
            assert.is_nil(uv.fs_lstat(bak))
        end)

        it("leaves nothing to recover after such a crash when the backup could only be emptied", function()
            spit(bak, older)
            unlink_fails()
            crash_after_create()

            assert.is_false((write({ quiet = true })))

            uv.fs_unlink, uv.fs_write = real_unlink, real_write
            assert.is_not_nil(uv.fs_lstat(file))
            assert.equals(0, uv.fs_stat(bak).size)
            assert.is_nil(read(), "a damaged cache was restored from an emptied backup")
        end)

        it("is emptied before the cache is created when it cannot be unlinked, and the write succeeds", function()
            spit(bak, older)
            unlink_fails()
            local seen = {}
            uv.fs_write = function(fd, data, offset)
                if data == payload and not seen.size then seen.size = uv.fs_stat(bak).size end
                return real_write(fd, data, offset)
            end

            local ok, err = write()

            assert.is_true(ok, tostring(err))
            assert.equals(0, seen.size, "the backup was still full when the new cache was written")
            assert.equals(0, uv.fs_stat(bak).size)
            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.equals(1, #warnings, vim.inspect(warnings))
        end)

        it("refuses the write, creating nothing, when it can be neither removed nor emptied", function()
            spit(bak, older)
            unlink_fails()
            empty_fails()

            local ok, err = write()

            uv.fs_open = real_open
            assert.is_false(ok)
            assert.matches(vim.pesc(bak), err)
            assert.matches("delete", err)
            assert.is_nil(uv.fs_lstat(file), "a cache was created beside a backup that could not be dealt with")
            assert.equals(older, slurp(bak))
            assert.equals(1, #errors, vim.inspect(errors))
        end)

        it("says nothing about refusing when the write is quiet", function()
            spit(bak, older)
            unlink_fails()
            empty_fails()

            assert.is_false((write({ quiet = true })))

            assert.same({}, errors)
            assert.same({}, warnings)
        end)

        it("is removed, whatever it holds: undecodable, or empty", function()
            for _, held in ipairs({ "{ torn", "" }) do
                spit(bak, held)

                assert.is_true((write()))

                assert.is_nil(uv.fs_lstat(bak))
                vim.fn.delete(file)
            end
        end)

        it("is a directory: not a backup, cannot be removed, so the write is refused and nothing is created", function()
            vim.fn.mkdir(bak)

            local ok, err = write()

            assert.is_false(ok)
            assert.matches(vim.pesc(bak), err)
            assert.is_nil(uv.fs_lstat(file))
        end)

        it("is not touched when the cache cannot be created at all: a refused link target", function()
            local middle = tmp .. "/middle.json"
            uv.fs_symlink(tmp .. "/nowhere.json", middle)
            uv.fs_symlink(middle, file)
            spit(bak, older)

            assert.is_false((write()))

            assert.equals(older, slurp(bak), "a backup was discarded though nothing could be written")
        end)

        it("does not change a plain new cache with no backup beside it", function()
            assert.is_true((write()))

            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.is_nil(uv.fs_lstat(bak))
            assert.same({}, warnings)
        end)
    end)

    describe("a backup that cannot be examined", function()
        -- Only ENOENT means absent. Anything else is unknown.
        local function bak_lstat_fails(code)
            uv.fs_lstat = function(path, ...)
                if path == bak then return nil, code .. ": cannot look: " .. path, code end
                return real_lstat(path, ...)
            end
        end

        for _, code in ipairs({ "EIO", "EACCES" }) do
            it(("refuses a write of a new cache, creating nothing (%s)"):format(code), function()
                bak_lstat_fails(code)

                local ok, err = write()

                uv.fs_lstat = real_lstat
                assert.is_false(ok)
                assert.matches(vim.pesc(bak), err)
                assert.is_nil(uv.fs_lstat(file), "a cache was written beside a backup that could not be examined")
                assert.equals(1, #errors, vim.inspect(errors))
            end)
        end

        it("refuses a write over a good cache too, touching nothing", function()
            spit(file, older)
            bak_lstat_fails("EIO")

            local ok, err = write()

            uv.fs_lstat = real_lstat
            assert.is_false(ok)
            assert.matches(vim.pesc(bak), err)
            assert.equals(older, slurp(file))
        end)

        it("refuses a write over a damaged cache, touching nothing", function()
            spit(file, "{ torn")
            bak_lstat_fails("EIO")

            local ok = write()

            uv.fs_lstat = real_lstat
            assert.is_false(ok)
            assert.equals("{ torn", slurp(file))
        end)

        it("says nothing when the write is quiet", function()
            bak_lstat_fails("EIO")

            assert.is_false((write({ quiet = true })))

            assert.same({}, errors)
        end)

        it("recovers nothing on a read, and creates nothing", function()
            bak_lstat_fails("EIO")

            assert.is_nil(read())

            uv.fs_lstat = real_lstat
            assert.is_nil(uv.fs_lstat(file))
            assert.same({}, warnings)
        end)

        it("is absent when lstat says ENOENT, which is the one error that means so", function()
            assert.is_true((write()))
            assert.same(fresh, vim.json.decode(slurp(file)))
        end)
    end)

    describe("an absent cache with a good backup beside it", function()
        -- Every write over an existing cache is in place, so an interrupted one leaves the
        -- cache present and damaged. An absent cache was deleted, and stays so.
        it("returns nil on a read and touches nothing", function()
            spit(bak, older)
            local before = uv.fs_stat(bak)

            assert.is_nil(read())

            assert.is_nil(uv.fs_lstat(file))
            assert.equals(older, slurp(bak))
            assert.equals(before.mtime.nsec, uv.fs_stat(bak).mtime.nsec)
            assert.same({}, warnings)
        end)

        it("gets a new cache from the next write, and the stale backup goes", function()
            spit(bak, older)

            assert.is_true((write()))

            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.is_nil(uv.fs_lstat(bak))
        end)

        it("gets a new cache from the next write, and the stale backup is emptied when it cannot go", function()
            spit(bak, older)
            uv.fs_unlink = function(path)
                if path == bak then return nil, "EPERM: operation not permitted: " .. path, "EPERM" end
                return real_unlink(path)
            end

            assert.is_true((write()))

            assert.equals(0, uv.fs_stat(bak).size)
            spit(file, "{ torn") -- damaged later
            assert.is_nil(read(), "an emptied backup brought the old cache back")
        end)

        it("still has a damaged cache beside a good backup recovered", function()
            spit(file, "{ torn")
            spit(bak, older)

            assert.same({ older = string.rep("o", 300) }, read())
            assert.equals(older, slurp(file))
        end)
    end)

    describe("deleting a cache", function()
        local function unlink_fails()
            uv.fs_unlink = function(path)
                if path == bak then return nil, "EPERM: operation not permitted: " .. path, "EPERM" end
                return real_unlink(path)
            end
        end

        --- ...and the backup cannot be emptied either: the one open for writing it is not the create.
        local function empty_fails()
            uv.fs_open = function(path, flags, mode)
                if path == bak and is_write_open(flags) then return nil, "EACCES: permission denied: " .. path, "EACCES" end
                return real_open(path, flags, mode)
            end
        end

        it("drop returns true for a backup that is not there: ENOENT is success", function()
            assert.is_true((backup.drop(P:new(file))))
        end)

        it("drop unlinks a backup", function()
            spit(bak, older)

            assert.is_true((backup.drop(P:new(file))))

            assert.is_nil(uv.fs_lstat(bak))
        end)

        it("drop empties a backup it cannot unlink, so it can never be recovered from", function()
            spit(bak, older)
            unlink_fails()

            assert.is_true((backup.drop(P:new(file))))

            assert.equals(0, uv.fs_stat(bak).size)
            assert.is_nil(read(), "an emptied backup brought a deleted cache back")
        end)

        it("drop returns false, saying why, when it can neither unlink nor empty it", function()
            spit(bak, older)
            unlink_fails()
            empty_fails()

            local ok, err = backup.drop(P:new(file))

            assert.is_false(ok)
            assert.matches(vim.pesc(bak), err)
            assert.matches("emptied", err)
        end)

        it("a stash is deleted, and stays deleted, when its backup could only be emptied", function()
            local stash = require("codewars.cache.stash").for_kind("t-stash-")
            local path = assert(stash.save({ id = "k1", code = "x" }))
            spit(path .. ".bak", vim.json.encode({ id = "k1", code = "old" }))
            bak = path .. ".bak"
            unlink_fails()

            assert.is_true(stash.delete("k1"))

            assert.is_nil(stash.get("k1"))
            assert.equals(0, uv.fs_stat(bak).size)
        end)

        it("a stash is deleted, and the user warned, when its backup can be neither removed nor emptied", function()
            local stash = require("codewars.cache.stash").for_kind("t-stash-")
            local path = assert(stash.save({ id = "k1", code = "x" }))
            spit(path .. ".bak", vim.json.encode({ id = "k1", code = "old" }))
            bak = path .. ".bak"
            unlink_fails()
            empty_fails()

            local removed = stash.delete("k1")

            uv.fs_open = real_open
            assert.is_true(removed)
            assert.equals(1, #warnings, vim.inspect(warnings))
            assert.is_nil(uv.fs_lstat(path))
            assert.is_nil(stash.get("k1"), "the deleted stash came back from its backup")
            assert.is_nil(uv.fs_lstat(path), "reading the deleted stash recreated it")
        end)

        it("a session is deleted, and the user warned, when its backup can be neither removed nor emptied", function()
            local session = require("codewars.cache.session")
            vim.fn.mkdir(cache_utils.cache_file("sessions"):absolute(), "p")
            session.save("two-sum", "python", { solutionId = "s1" })
            local path = cache_utils.cache_file("sessions"):joinpath("two-sum_python.json"):absolute()
            spit(path .. ".bak", vim.json.encode({ solutionId = "s0", cached_at = os.time() }))
            bak = path .. ".bak"
            unlink_fails()
            empty_fails()

            session.delete("two-sum", "python")

            uv.fs_open = real_open
            assert.is_nil(uv.fs_lstat(path), "the session was kept")
            assert.equals(1, #warnings, vim.inspect(warnings))
            assert.matches("by hand", warnings[1])
            assert.is_nil(session.get("two-sum", "python"), "a deleted session came back from its backup")
            assert.is_nil(uv.fs_lstat(path), "reading the deleted session recreated it")
        end)

        it("a session is deleted, and stays deleted, when its backup could only be emptied", function()
            local session = require("codewars.cache.session")
            vim.fn.mkdir(cache_utils.cache_file("sessions"):absolute(), "p")
            session.save("two-sum", "python", { solutionId = "s1" })
            local path = cache_utils.cache_file("sessions"):joinpath("two-sum_python.json"):absolute()
            spit(path .. ".bak", vim.json.encode({ solutionId = "s0", cached_at = os.time() }))
            bak = path .. ".bak"
            unlink_fails()

            session.delete("two-sum", "python")

            assert.is_nil(session.get("two-sum", "python"))
            assert.same({}, warnings)
        end)

        it("clearing all sessions warns about a backup it cannot remove, and goes on", function()
            local session = require("codewars.cache.session")
            local dir = cache_utils.cache_file("sessions"):absolute()
            vim.fn.mkdir(dir, "p")
            session.save("a", "python", { solutionId = "1" })
            spit(dir .. "/a_python.json.bak", "{}")
            bak = dir .. "/a_python.json.bak"
            unlink_fails()
            empty_fails()

            assert.equals(1, session.clear_all())

            uv.fs_open = real_open
            assert.equals(1, #warnings, vim.inspect(warnings))
        end)

        it("a profile is cleared, and the user warned, when its backup can be neither removed nor emptied", function()
            local profile = require("codewars.cache.profile")
            local path = cache_utils.cache_file("profile.json"):absolute()
            spit(path, "{}")
            spit(path .. ".bak", vim.json.encode({ username = "old" }))
            bak = path .. ".bak"
            unlink_fails()
            empty_fails()

            profile.clear()

            uv.fs_open = real_open
            assert.is_nil(uv.fs_lstat(path))
            assert.equals(1, #warnings, vim.inspect(warnings))
            assert.is_nil(cache_utils.read_json(P:new(path)), "a cleared profile came back from its backup")
            assert.is_nil(uv.fs_lstat(path), "reading the cleared profile recreated it")
        end)

        it("a profile stays cleared when its backup could only be emptied", function()
            local profile = require("codewars.cache.profile")
            local path = cache_utils.cache_file("profile.json"):absolute()
            spit(path, "{}")
            spit(path .. ".bak", vim.json.encode({ username = "old" }))
            bak = path .. ".bak"
            unlink_fails()

            profile.clear()

            assert.is_nil(cache_utils.read_json(P:new(path)))
            assert.same({}, warnings)
        end)

        it("the completed cache is cleared, and the user warned, when a backup can be neither removed nor emptied", function()
            local completed = require("codewars.cache.completed")
            local list = cache_utils.cache_file("completed.json"):absolute()
            spit(list, "{}")
            spit(list .. ".bak", "{}")
            bak = list .. ".bak"
            unlink_fails()
            empty_fails()

            completed.clear()

            uv.fs_open = real_open
            assert.is_nil(uv.fs_lstat(list))
            assert.equals(1, #warnings, vim.inspect(warnings))
            assert.is_nil(cache_utils.read_json(P:new(list)), "a cleared cache came back from its backup")
            assert.is_nil(uv.fs_lstat(list))
        end)

        it("the problem list is deleted, and the user warned, when a backup can be neither removed nor emptied", function()
            local problemlist = require("codewars.cache.problemlist")
            local list = cache_utils.cache_file("problemlist.json"):absolute()
            spit(list, "{}")
            spit(list .. ".bak", "{}")
            bak = list .. ".bak"
            unlink_fails()
            empty_fails()

            problemlist.delete()

            uv.fs_open = real_open
            assert.is_nil(uv.fs_lstat(list))
            assert.equals(1, #warnings, vim.inspect(warnings))
        end)
    end)
end)
