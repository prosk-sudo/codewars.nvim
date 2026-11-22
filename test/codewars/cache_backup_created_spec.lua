-- A file created with O_CREAT|O_EXCL is ours: if anything fails after that it is removed, or emptied if it can't be;
-- if neither works the error names it. A file that was already there is never unlinked for a failed write.
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

describe("cache.backup, a file that was created and then failed", function()
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local cache_utils = require("codewars.cache.utils")
    local backup = require("codewars.cache.backup")
    local saved_storage, real_error, real_warn, errors
    local real_open, real_fstat, real_ftruncate, real_fchmod, real_fsync, real_close, real_unlink, real_write
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
        real_write = uv.fs_write
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
        uv.fs_write = real_write
        config.storage, log.error, log.warn = saved_storage, real_error, real_warn
        vim.fn.delete(tmp, "rf")
    end)

    local function write() return cache_utils.write_json(P:new(file), fresh) end

    --- Make `step` ("fstat", the truncation, the mode, the flush or the close) fail on the descriptor just
    --- opened for writing `path`. Other descriptors are not touched.
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

    -- The clean-up can fail too (an I/O error on the unlink): the file is emptied first, while still open;
    -- an empty file never decodes, so it cannot be recovered from.
    describe("when the clean-up of a file that was created fails as well", function()
        -- A prefix that is itself valid JSON, which is what makes a partial file dangerous.
        local number = "1234567890123456"

        --- The write of `bytes` lands a valid-JSON prefix and then fails; unlinking `path` fails too.
        local function fails_after_a_valid_prefix_and_cannot_unlink(bytes, path)
            uv.fs_write = function(fd, data, offset)
                if data == bytes then
                    real_write(fd, data:sub(1, 8), offset)
                    return nil, "ENOSPC: no space left on device"
                end
                return real_write(fd, data, offset)
            end
            uv.fs_unlink = function(p)
                if p == path then return nil, "EIO: i/o error: " .. p, "EIO" end
                return real_unlink(p)
            end
        end

        it("empties a fresh backup first, so no part of the copy is left behind", function()
            spit(file, number) -- a good cache, and one whose copy has a valid prefix
            fails_after_a_valid_prefix_and_cannot_unlink(backup.frame_backup(number), bak)

            local ok, err = cache_utils.write_json(P:new(file), 1, { quiet = true })

            uv.fs_write, uv.fs_unlink = real_write, real_unlink
            assert.is_false(ok)
            assert.matches("ENOSPC", err)
            assert.matches(vim.pesc(bak), err)
            assert.matches("could not be removed", err)
            assert.matches("emptied", err)
            assert.equals(number, slurp(file))
            assert.equals(0, uv.fs_stat(bak).size, "a partial backup was left holding the start of the copy")
            spit(file, "{ torn") -- the cache is damaged later
            assert.is_nil(cache_utils.read_json(P:new(file)), "the prefix of a failed backup was recovered as the cache")
        end)

        it("empties a new cache first, and says so", function()
            fails_after_a_valid_prefix_and_cannot_unlink(number, file)

            local ok, err = cache_utils.write_json(P:new(file), tonumber(number), { quiet = true })

            uv.fs_write, uv.fs_unlink = real_write, real_unlink
            assert.is_false(ok)
            assert.matches("ENOSPC", err)
            assert.matches(vim.pesc(file), err)
            assert.matches("could not be removed", err)
            assert.matches("emptied", err)
            assert.equals(0, uv.fs_stat(file).size, "a partial cache was left holding a valid prefix")
        end)

        it("reports it through the log unless the write is quiet", function()
            fails_after_a_valid_prefix_and_cannot_unlink(number, file)

            cache_utils.write_json(P:new(file), tonumber(number))

            uv.fs_write, uv.fs_unlink = real_write, real_unlink
            assert.equals(1, #errors, vim.inspect(errors))
            assert.matches("could not be removed", errors[1])
        end)

        it("names the file to delete by hand when it can be neither removed nor emptied", function()
            fails_after_a_valid_prefix_and_cannot_unlink(number, file)
            local fds = {}
            local open = uv.fs_open
            uv.fs_open = function(p, flags, mode)
                local fd, err, name = open(p, flags, mode)
                if fd and p == file then fds[fd] = true end
                return fd, err, name
            end
            uv.fs_ftruncate = function(fd, ...)
                if fds[fd] then return nil, "EIO: i/o error" end
                return real_ftruncate(fd, ...)
            end

            local ok, err = cache_utils.write_json(P:new(file), tonumber(number), { quiet = true })

            uv.fs_write, uv.fs_unlink = real_write, real_unlink
            assert.is_false(ok)
            assert.matches(vim.pesc(file), err)
            assert.matches("could not be emptied", err)
            assert.matches("by hand", err)
        end)

        it("does not mention a clean-up when the unlink works: the file is simply gone", function()
            uv.fs_write = function(fd, data, offset)
                if data == number then
                    real_write(fd, data:sub(1, 8), offset)
                    return nil, "ENOSPC: no space left on device"
                end
                return real_write(fd, data, offset)
            end

            local ok, err = cache_utils.write_json(P:new(file), tonumber(number), { quiet = true })

            uv.fs_write = real_write
            assert.is_false(ok)
            assert.matches("ENOSPC", err)
            assert.is_nil(err:match("could not be removed"))
            assert.is_nil(uv.fs_lstat(file))
        end)
    end)

    -- A failed close leaves no descriptor to empty through: the path is unlinked, else reopened (no create, no
    -- truncate), checked to be the file that was created, and emptied if it is.
    describe("when the close of a created file fails", function()
        local stash_id = "0123456789abcdef01234567"

        --- The close of the descriptor that created `path` fails (after really closing it). The
        --- reopen that follows is made to fail in the way `second` says: "open", "identity", "truncate".
        local function close_fails(path, second)
            local opens, first, again = 0, nil, nil
            uv.fs_open = function(p, flags, mode)
                local fd, err, name = real_open(p, flags, mode)
                if fd and p == path and is_write_open(flags) then
                    opens = opens + 1
                    if opens == 1 then
                        first = fd
                    elseif second == "open" then
                        real_close(fd)
                        return nil, "EACCES: permission denied: " .. p, "EACCES"
                    else
                        again = fd
                    end
                end
                return fd, err, name
            end
            uv.fs_close = function(fd)
                local was_first = fd == first
                if was_first then first = nil end
                if fd == again then again = nil end
                local ok = real_close(fd)
                if was_first then return nil, "EIO: i/o error on close" end
                return ok
            end
            uv.fs_fstat = function(fd)
                local st = real_fstat(fd)
                if st and fd == again and second == "identity" then st.ino = st.ino + 1 end
                return st
            end
            uv.fs_ftruncate = function(fd, ...)
                if fd == again and second == "truncate" then return nil, "EIO: i/o error" end
                return real_ftruncate(fd, ...)
            end
        end

        local function unlink_fails(path)
            uv.fs_unlink = function(p)
                if p == path then return nil, "EIO: i/o error: " .. p, "EIO" end
                return real_unlink(p)
            end
        end

        it("empties the file by reopening it when it cannot be unlinked, and says so", function()
            close_fails(file)
            unlink_fails(file)

            local ok, err = cache_utils.write_json(P:new(file), fresh, { quiet = true })

            uv.fs_open, uv.fs_close = real_open, real_close
            assert.is_false(ok)
            assert.matches("on close", err)
            assert.matches(vim.pesc(file), err)
            assert.matches("was emptied", err)
            assert.equals(0, uv.fs_stat(file).size, "the file that was reported as not written was left populated")
            assert.is_nil(cache_utils.read_json(P:new(file)))
        end)

        it("leaves a stash that was reported as not saved unreadable", function()
            local stash = require("codewars.cache.stash").for_kind("t-stash-")
            local path = require("codewars.cache.utils").cache_file("t-stash-" .. stash_id .. ".json"):absolute()
            close_fails(path)
            unlink_fails(path)

            local saved = stash.save({ id = stash_id, code = "unsaved work" })

            uv.fs_open, uv.fs_close = real_open, real_close
            assert.is_nil(saved, "a stash whose close failed was reported as saved")
            assert.is_nil(stash.get(stash_id), "a stash reported as not saved can still be loaded")
        end)

        for _, second in ipairs({ "open", "identity", "truncate" }) do
            it(("names the file to delete by hand when it cannot be emptied either (reopen %s)"):format(second), function()
                close_fails(file, second)
                unlink_fails(file)

                local ok, err = cache_utils.write_json(P:new(file), fresh, { quiet = true })

                uv.fs_open, uv.fs_close, uv.fs_fstat, uv.fs_ftruncate = real_open, real_close, real_fstat, real_ftruncate
                assert.is_false(ok)
                assert.matches("on close", err)
                assert.matches(vim.pesc(file), err)
                assert.matches("could not be emptied", err)
                assert.matches("by hand", err)
            end)
        end

        it("leaves no file when it can be unlinked, and says nothing about a clean-up", function()
            close_fails(file)

            local ok, err = cache_utils.write_json(P:new(file), fresh, { quiet = true })

            uv.fs_open, uv.fs_close = real_open, real_close
            assert.is_false(ok)
            assert.matches("on close", err)
            assert.is_nil(err:match("could not be removed"))
            assert.is_nil(uv.fs_lstat(file))
        end)

        it("is the same for a fresh backup: emptied, and never recovered", function()
            spit(file, vim.json.encode({ old = string.rep("o", 100) }))
            close_fails(bak)
            unlink_fails(bak)

            local ok, err = cache_utils.write_json(P:new(file), fresh, { quiet = true })

            uv.fs_open, uv.fs_close = real_open, real_close
            assert.is_false(ok)
            assert.matches(vim.pesc(bak), err)
            assert.matches("was emptied", err)
            assert.equals(0, uv.fs_stat(bak).size)
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
            put(bak, original)
            uv.fs_unlink = function(path)
                if path == bak then return nil, "EPERM: operation not permitted: " .. path, "EPERM" end
                return real_unlink(path)
            end
            fail_on(bak, "fstat")

            local ok = backup.drop(P:new(file))

            assert.is_false(ok)
            assert.equals(original, payload_of(bak), "an existing backup was unlinked or changed")
        end)
    end)
end)
