-- The cache file as the backup logic meets it: recovery only over a present cache that is empty or undecodable;
-- opens are non-blocking (where luv has O_NONBLOCK) and fstat-checked; a backup that cannot be removed is emptied.
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

describe("cache.utils, the cache file", function()
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local cache_utils = require("codewars.cache.utils")
    local saved_storage, real_error, real_warn, errors, warnings
    local real_open, real_read, real_fstat, real_unlink, real_ftruncate, real_write, real_close, real_lstat
    local tmp, file, bak, newer, older, original, fresh

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
        real_open, real_read, real_fstat = uv.fs_open, uv.fs_read, uv.fs_fstat
        real_unlink, real_ftruncate, real_write = uv.fs_unlink, uv.fs_ftruncate, uv.fs_write
        real_close, real_lstat = uv.fs_close, uv.fs_lstat
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        log.error = function(msg) errors[#errors + 1] = tostring(msg) end
        log.warn = function(msg) warnings[#warnings + 1] = tostring(msg) end
        file, bak = tmp .. "/cache.json", tmp .. "/cache.json.bak"
        newer = vim.json.encode({ newer = string.rep("n", 300) })
        older = vim.json.encode({ older = string.rep("o", 300) })
        original = newer
        fresh = { fresh = string.rep("f", 600) }
    end)

    after_each(function()
        uv.fs_open, uv.fs_read, uv.fs_fstat = real_open, real_read, real_fstat
        uv.fs_unlink, uv.fs_ftruncate, uv.fs_write = real_unlink, real_ftruncate, real_write
        uv.fs_close, uv.fs_lstat = real_close, real_lstat
        config.storage, log.error, log.warn = saved_storage, real_error, real_warn
        pcall(uv.fs_chmod, file, 420)
        vim.fn.delete(tmp, "rf")
    end)

    local function write(opts) return cache_utils.write_json(P:new(file), fresh, opts) end
    local function read() return cache_utils.read_json(P:new(file)) end

    --- The cache cannot be read: the open ("open"), a read ("read") or the descriptor check ("descriptor") fails.
    --- Opens for writing are not touched.
    local function main_unreadable(how)
        local fds = {}
        uv.fs_close = function(fd)
            fds[fd] = nil -- descriptor numbers are reused
            return real_close(fd)
        end
        uv.fs_open = function(path, flags, mode)
            if path ~= file or is_write_open(flags) then return real_open(path, flags, mode) end
            if how == "open" then return nil, "EIO: i/o error: " .. file, "EIO" end
            local fd, err, name = real_open(path, flags, mode)
            if fd then fds[fd] = true end
            return fd, err, name
        end
        uv.fs_read = function(fd, size, offset)
            if how == "read" and fds[fd] then return nil, "EIO: i/o error" end
            return real_read(fd, size, offset)
        end
        uv.fs_fstat = function(fd)
            local st = real_fstat(fd)
            if st and how == "descriptor" and fds[fd] then st.type = "fifo" end
            return st
        end
    end

    local function times(path)
        local st = uv.fs_stat(path)
        return st.mtime.sec, st.mtime.nsec
    end

    describe("that cannot be read", function()
        for _, how in ipairs({ "open", "read", "descriptor", "mode" }) do
            local function make_unreadable()
                if how ~= "mode" then return main_unreadable(how) end
                uv.fs_chmod(file, 0)
                return not uv.fs_access(file, "R")
            end

            it(("is not recovered over by a read, and neither file is touched (%s error)"):format(how), function()
                spit(file, newer) -- good, and newer than the backup an interrupted write left
                put(bak, older)
                local file_sec, file_nsec = times(file)
                local bak_sec, bak_nsec = times(bak)
                if make_unreadable() == false then return pending("running as a user that ignores file modes") end

                local data = read()

                uv.fs_open, uv.fs_read, uv.fs_fstat = real_open, real_read, real_fstat
                uv.fs_chmod(file, 420)
                assert.is_nil(data)
                assert.equals(newer, slurp(file), "the newer cache was replaced by the older backup")
                assert.equals(older, payload_of(bak))
                assert.same({ file_sec, file_nsec }, { times(file) })
                assert.same({ bak_sec, bak_nsec }, { times(bak) })
                assert.same({}, warnings)
            end)

            it(("makes a write refuse, with neither file touched (%s error)"):format(how), function()
                spit(file, newer)
                put(bak, older)
                local file_sec, file_nsec = times(file)
                if make_unreadable() == false then return pending("running as a user that ignores file modes") end

                local ok, err = write()

                uv.fs_open, uv.fs_read, uv.fs_fstat = real_open, real_read, real_fstat
                uv.fs_chmod(file, 420)
                assert.is_false(ok)
                assert.matches("could not back up", err)
                assert.equals(newer, slurp(file))
                assert.equals(older, payload_of(bak), "the backup was replaced though the cache could not be read")
                assert.same({ file_sec, file_nsec }, { times(file) })
                assert.equals(1, #errors, vim.inspect(errors))
            end)
        end

        it("is still recovered from when it was read in full and is damaged", function()
            spit(file, "{ torn")
            put(bak, older)

            assert.same({ older = string.rep("o", 300) }, read())
            assert.equals(older, slurp(file))
        end)

        it("is not recovered when it is absent: the backup of a deleted cache does not bring it back", function()
            put(bak, older)

            assert.is_nil(read())

            assert.is_nil(uv.fs_lstat(file))
            assert.equals(older, payload_of(bak))
        end)
    end)

    describe("opened for writing", function()
        local function has(flags, bits) return bit.band(flags, bits) == bits end

        local function record_write_opens()
            local opens = {}
            uv.fs_open = function(path, flags, mode)
                if is_write_open(flags) then opens[#opens + 1] = { path = path, flags = flags } end
                return real_open(path, flags, mode)
            end
            return opens
        end

        local function assert_never_blocking_or_truncating(opens)
            assert.is_true(#opens > 0, "nothing was opened for writing")
            for _, open in ipairs(opens) do
                assert.equals("number", type(open.flags), open.path .. " was opened by name")
                assert.is_true(has(open.flags, bit.bor(C.O_WRONLY, C.O_NONBLOCK)),
                    open.path .. " was opened for writing without O_NONBLOCK, which can wait on a pipe for ever")
                assert.is_false(has(open.flags, C.O_TRUNC), open.path .. " was truncated by the open, before any check")
            end
        end

        it("never blocks or truncates, and only creates where it is creating", function()
            if not C.O_NONBLOCK then return pending("this luv does not expose the open flags") end
            spit(file, original)
            local opens = record_write_opens()
            assert.is_true((write())) -- in place over a good cache: backup created exclusively, cache rewritten
            local backup_open, cache_open = opens[1], opens[2]
            assert_never_blocking_or_truncating(opens)
            assert.equals(bak, backup_open.path)
            assert.is_true(has(backup_open.flags, bit.bor(C.O_CREAT, C.O_EXCL)))
            assert.equals(file, cache_open.path)
            assert.is_false(has(cache_open.flags, C.O_CREAT), "the cache was opened as if it might not be there")

            local other = tmp .. "/other.json"
            opens = record_write_opens()
            assert.is_true((cache_utils.write_json(P:new(other), fresh))) -- a new file
            assert_never_blocking_or_truncating(opens)
            assert.is_true(has(opens[1].flags, bit.bor(C.O_CREAT, C.O_EXCL)), "a new cache is created exclusively")

            spit(file, "{ torn")
            put(bak, older)
            opens = record_write_opens()
            read() -- recovery over a damaged cache
            assert_never_blocking_or_truncating(opens)
            assert.is_false(has(opens[1].flags, C.O_CREAT))

            uv.fs_unlink(file)
            put(bak, older)
            opens = record_write_opens()
            read() -- a cache that is not there is not recovered: nothing is opened for writing
            assert.same({}, opens)
        end)

        --- Make the descriptor the cache is opened on differ from what was read, and count what is done to it.
        local function descriptor_says(change)
            local fds, done = {}, { truncated = false, written = false }
            uv.fs_close = function(fd)
                fds[fd] = nil -- descriptor numbers are reused
                return real_close(fd)
            end
            uv.fs_open = function(path, flags, mode)
                local fd, err, name = real_open(path, flags, mode)
                if fd and path == file and is_write_open(flags) then fds[fd] = true end
                return fd, err, name
            end
            uv.fs_fstat = function(fd)
                local st = real_fstat(fd)
                if st and fds[fd] then change(st) end
                return st
            end
            uv.fs_ftruncate = function(fd, ...)
                if fds[fd] then done.truncated = true end
                return real_ftruncate(fd, ...)
            end
            uv.fs_write = function(fd, ...)
                if fds[fd] then done.written = true end
                return real_write(fd, ...)
            end
            return done
        end

        local swaps = {
            ["is not a regular file"] = function(st) st.type = "fifo" end,
            ["is another file than the one that was read"] = function(st) st.ino = st.ino + 1 end,
            ["is on another device than the one that was read"] = function(st) st.dev = st.dev + 1 end,
        }

        for name, change in pairs(swaps) do
            it(("refuses an in-place write, before truncating, when the descriptor %s"):format(name), function()
                spit(file, original)
                local done = descriptor_says(change)

                local ok, err = write()

                uv.fs_open, uv.fs_fstat, uv.fs_ftruncate, uv.fs_write = real_open, real_fstat, real_ftruncate, real_write
                assert.is_false(done.truncated or done.written, "the file was truncated or written after failing the check")
                assert.is_false(ok)
                assert.is_string(err)
                assert.equals(original, slurp(file))
                assert.is_nil(uv.fs_lstat(bak), "its own backup was left behind")
            end)

            it(("refuses recovery, before truncating, when the descriptor %s"):format(name), function()
                spit(file, "{ torn")
                put(bak, older)
                local done = descriptor_says(change)

                local data = read()

                uv.fs_open, uv.fs_fstat, uv.fs_ftruncate, uv.fs_write = real_open, real_fstat, real_ftruncate, real_write
                assert.is_false(done.truncated or done.written, "the file was truncated or written after failing the check")
                assert.same({ older = string.rep("o", 300) }, data, "the recovered data is still returned")
                assert.equals("{ torn", slurp(file))
                assert.equals(older, payload_of(bak))
            end)
        end

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

        --- The cache is swapped for a pipe between the read and the open for writing.
        local function child_body(call)
            return ([[
local uv = vim.uv or vim.loop
local backup = require("codewars.cache.backup")
local FILE, BAK = %s, %s
local function parse(t) local ok, d = pcall(vim.json.decode, t); return ok and d or nil end
local function spit(p, t) local f = assert(io.open(p, "wb")); f:write(t); f:close() end
local real_open = uv.fs_open
local function swap_on_open_for_writing()
    uv.fs_open = function(path, flags, mode)
        if path == FILE and type(flags) == "number" and bit.band(flags, (uv.constants or {}).O_WRONLY or 1) ~= 0 then
            os.remove(FILE)
            vim.fn.system({ "mkfifo", FILE })
        end
        return real_open(path, flags, mode)
    end
end
%s
]]):format(vim.inspect(file), vim.inspect(bak), call)
        end

        it("does not block recovery when the cache is swapped for a pipe after it was read", function()
            if not can_run_child() then return pending("needs vim.system (Neovim 0.10) and mkfifo") end

            local res = in_child(child_body(([[
spit(FILE, "{ torn")
spit(BAK, backup.frame_backup(%s))
local state, _, stat = backup.read_main(FILE)
swap_on_open_for_writing()
local data, err = backup.settle(FILE, parse, stat)
print("RESULT", state, tostring(data ~= nil), tostring(err))
]]):format(vim.inspect(older))), 5000)

            assert.is_true(res.done, "the open of the pipe for writing blocked: " .. res.text)
            assert.matches("RESULT%s+read%s+true%s+ENXIO", res.text)
        end)

        it("does not block an in-place write when the cache is swapped for a pipe after it was read", function()
            if not can_run_child() then return pending("needs vim.system (Neovim 0.10) and mkfifo") end

            local res = in_child(child_body(([[
spit(FILE, %s)
swap_on_open_for_writing()
local ok, err = backup.write(FILE, "{}", parse)
print("RESULT", tostring(ok), tostring(err), uv.fs_lstat(BAK) and "bak" or "nobak")
]]):format(vim.inspect(original))), 5000)

            assert.is_true(res.done, "the open of the pipe for writing blocked: " .. res.text)
            assert.matches("RESULT%s+false", res.text)
            assert.matches("ENXIO", res.text)
            assert.matches("nobak", res.text)
        end)
    end)

    describe("a backup that cannot be removed after a write that landed", function()
        local function unlink_fails()
            uv.fs_unlink = function(path)
                if path == bak then return nil, "EPERM: operation not permitted: " .. path, "EPERM" end
                return real_unlink(path)
            end
        end

        --- The backup cannot be emptied either: it opens for the exclusive create, and not again.
        local function empty_fails()
            local created = false
            uv.fs_open = function(path, flags, mode)
                if path == bak and is_write_open(flags) then
                    if not created then
                        created = true
                    else
                        return nil, "EACCES: permission denied: " .. path, "EACCES"
                    end
                end
                return real_open(path, flags, mode)
            end
        end

        it("is emptied instead, so the write still counts and the backup can never be recovered from", function()
            spit(file, original)
            unlink_fails()

            local ok, err = write()

            assert.is_true(ok, tostring(err))
            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.equals(0, uv.fs_stat(bak).size)
            assert.equals(1, #warnings, vim.inspect(warnings))
            spit(file, "{ torn") -- the cache is damaged later
            assert.is_nil(read(), "an emptied backup brought the old cache back")
            assert.equals("{ torn", slurp(file))
        end)

        it("says nothing about it when the write is quiet", function()
            spit(file, original)
            unlink_fails()

            assert.is_true((write({ quiet = true })))

            assert.same({}, warnings)
            assert.same({}, errors)
        end)

        it("is emptied too when it is the good copy the write kept", function()
            spit(file, "{ torn")
            put(bak, older)
            unlink_fails()

            assert.is_true((write()))

            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.equals(0, uv.fs_stat(bak).size)
        end)

        it("is emptied too when a new file lands beside it", function()
            put(bak, older)
            unlink_fails()

            assert.is_true((write()))

            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.equals(0, uv.fs_stat(bak).size)
        end)

        it("fails the write, saying the data was written and where the stale backup is, when it cannot be emptied", function()
            spit(file, original)
            unlink_fails()
            empty_fails()

            local ok, err = write()

            assert.is_false(ok)
            assert.matches("was written", err)
            assert.matches(vim.pesc(bak), err)
            assert.matches("by hand", err)
            assert.same(fresh, vim.json.decode(slurp(file)))
            assert.equals(1, #errors, vim.inspect(errors))
        end)

        -- Only ENOENT means gone; an unexaminable backup is "unknown" and must not make a write report a clean success.
        for _, code in ipairs({ "EIO", "EACCES" }) do
            it(("is not reported gone when it cannot be examined afterwards (%s)"):format(code), function()
                spit(file, original)
                local tried = false
                uv.fs_unlink = function(path)
                    if path == bak then
                        tried = true
                        return nil, "EPERM: operation not permitted: " .. path, "EPERM"
                    end
                    return real_unlink(path)
                end
                uv.fs_lstat = function(path, ...)
                    if path == bak and tried then return nil, code .. ": cannot look: " .. path, code end
                    return real_lstat(path, ...)
                end

                local ok, err = write()

                uv.fs_lstat = real_lstat
                assert.is_false(ok, "a backup that could not even be examined was reported as removed")
                assert.matches("was written", err)
                assert.matches(vim.pesc(bak), err)
                assert.matches("by hand", err)
                assert.same(fresh, vim.json.decode(slurp(file)))
                assert.equals(1, #errors, vim.inspect(errors))
            end)
        end

        it("is gone when it was removed between the failed unlink and the look: that is ENOENT", function()
            spit(file, original)
            uv.fs_unlink = function(path)
                if path == bak then
                    real_unlink(path)
                    return nil, "EPERM: operation not permitted: " .. path, "EPERM"
                end
                return real_unlink(path)
            end

            local ok, err = write()

            assert.is_true(ok, tostring(err))
            assert.is_nil(uv.fs_lstat(bak))
            assert.same({}, warnings)
        end)

        it("fails quietly the same way when the write is quiet", function()
            spit(file, original)
            unlink_fails()
            empty_fails()

            local ok, err = write({ quiet = true })

            assert.is_false(ok)
            assert.matches("by hand", err)
            assert.same({}, errors)
        end)
    end)
end)
