-- A file that an open with O_CREAT|O_EXCL created is ours. Whatever fails after
-- that (the descriptor check, ftruncate, fchmod, a write, fsync, close) takes it
-- away again, so no empty cache, resolved link target or empty .bak is left
-- behind and the failure is reported. A file that was already there (an open
-- without O_CREAT) is never unlinked because a write to it failed.
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

describe("cache.backup, a file that was created and then failed", function()
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local cache_utils = require("codewars.cache.utils")
    local backup = require("codewars.cache.backup")
    local saved_storage, real_error, real_warn, errors
    local real_open, real_fstat, real_ftruncate, real_fchmod, real_fsync, real_close, real_unlink
    local tmp, file, bak, original, fresh

    local C = uv.constants or {}
    local WRITE_BITS = bit.bor(C.O_WRONLY or 0, C.O_RDWR or 0, C.O_CREAT or 0)
    local function is_write_open(flags)
        return flags == "w" or flags == "wx" or flags == "r+"
            or (type(flags) == "number" and bit.band(flags, WRITE_BITS) ~= 0)
    end

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved_storage, real_error, real_warn, errors = config.storage, log.error, log.warn, {}
        real_open, real_fstat, real_ftruncate = uv.fs_open, uv.fs_fstat, uv.fs_ftruncate
        real_fchmod, real_fsync, real_close, real_unlink = uv.fs_fchmod, uv.fs_fsync, uv.fs_close, uv.fs_unlink
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        log.error = function(msg) errors[#errors + 1] = tostring(msg) end
        log.warn = function() end
        file, bak = tmp .. "/cache.json", tmp .. "/cache.json.bak"
        original = vim.json.encode({ old = string.rep("o", 300) })
        fresh = { fresh = string.rep("f", 600) }
    end)

    after_each(function()
        uv.fs_open, uv.fs_fstat, uv.fs_ftruncate = real_open, real_fstat, real_ftruncate
        uv.fs_fchmod, uv.fs_fsync, uv.fs_close, uv.fs_unlink = real_fchmod, real_fsync, real_close, real_unlink
        config.storage, log.error, log.warn = saved_storage, real_error, real_warn
        vim.fn.delete(tmp, "rf")
    end)

    local function write() return cache_utils.write_json(P:new(file), fresh) end

    --- Make `step` fail on the descriptor that was just opened for writing `path`:
    --- the stat of it ("fstat"), the truncation, the mode, the flush or the close.
    --- Only descriptors opened on `path` for writing are touched.
    local function fail_on(path, step)
        local fds = {}
        local function ours(fd) return fds[fd] end
        uv.fs_open = function(p, flags, mode)
            local fd, err, name = real_open(p, flags, mode)
            if fd and p == path and is_write_open(flags) then fds[fd] = true end
            return fd, err, name
        end
        uv.fs_close = function(fd)
            local was_ours = fds[fd]
            fds[fd] = nil -- descriptor numbers are reused
            local ok = real_close(fd)
            if was_ours and step == "close" then return nil, "EIO: i/o error on close" end
            return ok
        end
        uv.fs_fstat = function(fd)
            if ours(fd) and step == "fstat" then return nil, "EIO: i/o error", "EIO" end
            return real_fstat(fd)
        end
        uv.fs_ftruncate = function(fd, ...)
            if ours(fd) and step == "ftruncate" then return nil, "EIO: i/o error" end
            return real_ftruncate(fd, ...)
        end
        uv.fs_fchmod = function(fd, ...)
            if ours(fd) and step == "fchmod" then return nil, "EIO: i/o error" end
            return real_fchmod(fd, ...)
        end
        uv.fs_fsync = function(fd)
            if ours(fd) and step == "fsync" then return nil, "EIO: i/o error" end
            return real_fsync(fd)
        end
    end

    describe("a new cache", function()
        for _, step in ipairs({ "fstat", "ftruncate", "fsync", "close" }) do
            it(("is not left behind when the %s of it fails, and the failure is reported"):format(step), function()
                fail_on(file, step)

                local ok, err = write()

                assert.is_false(ok)
                assert.matches("EIO", err)
                assert.is_nil(uv.fs_lstat(file), "an empty or partial cache was left behind")
                assert.equals(1, #errors, vim.inspect(errors))
            end)
        end
    end)

    describe("a fresh backup", function()
        for _, step in ipairs({ "fstat", "ftruncate", "fchmod", "fsync", "close" }) do
            it(("is not left behind when the %s of it fails, and the cache is untouched"):format(step), function()
                spit(file, original)
                fail_on(bak, step)

                local ok, err = write()

                assert.is_false(ok)
                assert.matches("EIO", err)
                assert.is_nil(uv.fs_lstat(bak), "an empty or partial backup was left behind")
                assert.equals(original, slurp(file))
            end)
        end
    end)

    describe("the target of a dangling symlink that is the configured cache", function()
        it("is removed when the stat of it fails, and the link is intact", function()
            local target = tmp .. "/real-cache.json"
            uv.fs_symlink(target, file)
            fail_on(target, "fstat")

            local ok, err = write()

            assert.is_false(ok)
            assert.matches("EIO", err)
            assert.is_nil(uv.fs_lstat(target), "an empty target was left behind")
            assert.equals("link", uv.fs_lstat(file).type)
            assert.equals(target, uv.fs_readlink(file))
        end)
    end)

    describe("a file that was already there", function()
        it("is not unlinked when the stat of it fails during an in-place write", function()
            spit(file, original)
            fail_on(file, "fstat")

            local ok = write()

            assert.is_false(ok)
            assert.equals(original, slurp(file), "an existing cache was removed or changed")
            assert.is_nil(uv.fs_lstat(bak), "its own backup was left behind")
        end)

        it("is not unlinked when the truncation of it fails during an in-place write", function()
            spit(file, original)
            fail_on(file, "ftruncate")

            assert.is_false((write()))

            assert.is_not_nil(uv.fs_lstat(file), "an existing cache was removed")
        end)

        it("is not unlinked when a backup that cannot be unlinked cannot be examined to be emptied", function()
            spit(bak, original)
            uv.fs_unlink = function(path)
                if path == bak then return nil, "EPERM: operation not permitted: " .. path, "EPERM" end
                return real_unlink(path)
            end
            fail_on(bak, "fstat")

            local ok = backup.drop(P:new(file))

            assert.is_false(ok)
            assert.equals(original, slurp(bak), "an existing backup was unlinked or changed")
        end)
    end)
end)
