-- Covers: recovery on read (present, damaged cache; complete backup) and the cases that must not recover, a failed
-- restore read back, deleting a cache, and the scans over cache and solution folders.
local P = require("plenary.path")

-- A kata id: 24 hex digits, which the stash accepts.
local STASH_ID = "0123456789abcdef01234567"

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

describe("cache backups", function()
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local cache_utils = require("codewars.cache.utils")
    local saved_storage, real_warn, warnings, tmp

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved_storage, real_warn, warnings = config.storage, log.warn, {}
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        log.warn = function(msg) warnings[#warnings + 1] = tostring(msg) end
    end)

    after_each(function()
        config.storage, log.warn = saved_storage, real_warn
        vim.fn.delete(tmp, "rf")
    end)

    describe("read_json", function()
        local file, bak, good

        before_each(function()
            file, bak = tmp .. "/cache.json", tmp .. "/cache.json.bak"
            good = vim.json.encode({ kept = "yes" })
        end)

        local function read() return cache_utils.read_json(P:new(file)) end

        it("recovers from the backup when the file fails to decode", function()
            spit(file, '{"kept": "ye')
            put(bak, good)

            assert.same({ kept = "yes" }, read())

            assert.equals(good, slurp(file), "the backup was not written back")
            assert.equals(good, payload_of(bak), "a reader removed the backup; only a writer does")
            assert.equals(1, #warnings, vim.inspect(warnings))
        end)

        it("recovers from the backup when the file is empty", function()
            spit(file, "")
            put(bak, good)

            assert.same({ kept = "yes" }, read())
            assert.equals(good, slurp(file))
            assert.equals(good, payload_of(bak), "a reader removed the backup; only a writer does")
        end)

        -- An absent cache was deleted: an interrupted in-place write leaves it present and damaged,
        -- so a leftover backup must not bring it back.
        it("does nothing when the file is missing: a leftover backup does not bring a deleted cache back", function()
            put(bak, good)
            local before = uv.fs_stat(bak)

            assert.is_nil(read())

            assert.is_nil(uv.fs_lstat(file), "a deleted cache was recreated from its backup")
            assert.equals(good, payload_of(bak))
            assert.equals(before.mtime.nsec, uv.fs_stat(bak).mtime.nsec)
            assert.same({}, warnings)
        end)

        it("says so once, not on every read", function()
            spit(file, "")
            put(bak, good)

            read()
            read()

            assert.equals(1, #warnings, vim.inspect(warnings))
        end)

        -- Another editor may be between backing up and truncating: a cache that reads fine does not make
        -- the backup stale.
        it("leaves the backup alone when the file decodes fine", function()
            spit(file, vim.json.encode({ kept = "newer" }))
            put(bak, good)

            assert.same({ kept = "newer" }, read())

            assert.equals(good, payload_of(bak), "a reader removed a backup that may be in use")
            assert.same({}, warnings)
        end)

        it("does not use a backup that is a symlink, and does not touch its target", function()
            local target = tmp .. "/elsewhere.json"
            put(target, good)
            spit(file, "{ torn")
            uv.fs_symlink(target, bak)

            assert.is_nil(read())

            assert.equals("{ torn", slurp(file))
            assert.equals(good, payload_of(target))
            assert.equals("link", uv.fs_lstat(bak).type)
        end)

        for _, how in ipairs({ "open fails", "mode" }) do
            it(("does nothing when the backup cannot be read (%s): it may be the one good copy"):format(how), function()
                spit(file, "{ torn")
                put(bak, good)
                local real_open = uv.fs_open
                if how == "mode" then
                    uv.fs_chmod(bak, 0)
                    if uv.fs_access(bak, "R") then return pending("running as a user that ignores file modes") end
                else
                    uv.fs_open = function(path, flags, mode)
                        local writing = type(flags) == "number" and bit.band(flags, (uv.constants or {}).O_WRONLY or 1) ~= 0
                        if path == bak and not writing then
                            return nil, "EACCES: permission denied: " .. bak, "EACCES"
                        end
                        return real_open(path, flags, mode)
                    end
                end

                local data = read()

                uv.fs_open = real_open
                uv.fs_chmod(bak, 420)
                assert.is_nil(data)
                assert.equals("{ torn", slurp(file))
                assert.equals(good, payload_of(bak))
                assert.same({}, warnings)
            end)
        end

        it("does not use a backup that is not a regular file", function()
            spit(file, "{ torn")
            vim.fn.mkdir(bak)

            assert.is_nil(read())

            assert.equals("{ torn", slurp(file))
        end)

        it("does not use a backup that does not decode either", function()
            spit(file, "{ torn")
            put(bak, "{ also torn")

            assert.is_nil(read())

            assert.equals("{ torn", slurp(file))
        end)

        it("is untouched when there is no backup at all", function()
            assert.is_nil(read())
            assert.is_nil(uv.fs_stat(file), "reading a missing cache created it")
        end)
    end)

    describe("a failed restore that is read back", function()
        it("gives the previous cache back on the next read", function()
            local file = tmp .. "/cache.json"
            local original = vim.json.encode({ old = string.rep("o", 300) })
            local payload = vim.json.encode({ fresh = string.rep("n", 600) })
            local real_write, failed = uv.fs_write, false
            spit(file, original)
            uv.fs_write = function(fd, data, offset)
                if data == payload then
                    failed = true
                    real_write(fd, data:sub(1, 100), offset)
                    return nil, "ENOSPC: no space left on device"
                end
                if failed and data == original then return nil, "ENOSPC: no space left on device" end
                return real_write(fd, data, offset)
            end
            local ok = cache_utils.write_json(P:new(file), { fresh = string.rep("n", 600) }, { quiet = true })
            uv.fs_write = real_write
            assert.is_false(ok)

            assert.same({ old = string.rep("o", 300) }, cache_utils.read_json(P:new(file)))

            assert.equals(original, slurp(file))
        end)
    end)

    -- session.lua creates its directory once per process; each test here has a new one.
    local function sessions_dir()
        local dir = cache_utils.cache_file("sessions"):absolute()
        vim.fn.mkdir(dir, "p")
        return dir
    end

    describe("deleting a cache", function()
        it("drops the backup, so the cache is not recovered after it is deleted", function()
            local backup = require("codewars.cache.backup")
            local file = tmp .. "/gone.json"
            spit(file, "{}")
            put(file .. ".bak", vim.json.encode({ back = true }))

            vim.fn.delete(file)
            backup.drop(P:new(file))

            assert.is_nil(uv.fs_stat(file .. ".bak"))
            assert.is_nil(cache_utils.read_json(P:new(file)))
        end)

        it("drops a backup that has no cache beside it just the same", function()
            local backup = require("codewars.cache.backup")
            local file = tmp .. "/gone.json"
            put(file .. ".bak", "{}")

            backup.drop(P:new(file))

            assert.is_nil(uv.fs_stat(file .. ".bak"))
        end)

        it("does not bring a deleted stash back", function()
            local stash = require("codewars.cache.stash").for_kind("t-stash-")
            local path = assert(stash.save({ id = STASH_ID, code = "x" }))
            put(path .. ".bak", vim.json.encode({ id = STASH_ID, code = "old" }))

            assert.is_true(stash.delete(STASH_ID))

            assert.is_nil(stash.get(STASH_ID))
            assert.is_nil(uv.fs_stat(path .. ".bak"))
        end)

        it("does not bring a deleted session back", function()
            local session = require("codewars.cache.session")
            sessions_dir()
            session.save("two-sum", "python", { solutionId = "s1" })
            local path = cache_utils.cache_file("sessions"):joinpath("two-sum_python.json"):absolute()
            put(path .. ".bak", vim.json.encode({ solutionId = "s0", cached_at = os.time() }))

            session.delete("two-sum", "python")

            assert.is_nil(session.get("two-sum", "python"))
            assert.is_nil(uv.fs_stat(path .. ".bak"))
        end)

        it("does not bring back a cleared profile", function()
            local profile = require("codewars.cache.profile")
            local path = cache_utils.cache_file("profile.json"):absolute()
            spit(path, "{}")
            put(path .. ".bak", vim.json.encode({ username = "old" }))

            profile.clear()

            assert.is_nil(uv.fs_stat(path .. ".bak"))
            assert.is_nil(cache_utils.read_json(P:new(path)))
        end)
    end)

    describe("the scans over cache and solution folders", function()
        it("session.clear_all counts sessions, not their backups, and clears the backups too", function()
            local session = require("codewars.cache.session")
            local dir = sessions_dir()
            session.save("a", "python", { solutionId = "1" })
            session.save("b", "python", { solutionId = "2" })
            put(dir .. "/a_python.json.bak", "{}")
            put(dir .. "/orphan_python.json.bak", "{}")

            assert.equals(2, session.clear_all())

            assert.same({}, vim.fn.readdir(dir), "a backup survived clear_all, and would bring a session back")
        end)

        it("session.count counts sessions, not their backups", function()
            local session = require("codewars.cache.session")
            local dir = sessions_dir()
            session.save("a", "python", { solutionId = "1" })
            put(dir .. "/a_python.json.bak", "{}")
            put(dir .. "/orphan_python.json.bak", "{}")

            assert.equals(1, session.count())
        end)

        it("unfinished.list does not list a solution's backup or the record's", function()
            local unfinished = require("codewars.unfinished")
            local saved_langs = config.langs
            -- A language whose files end in .bak: the only way the extension alone could mistake a backup for one.
            config.langs = vim.list_extend(vim.deepcopy(saved_langs), { { ft = "bak", slug = "bakish" } })
            local ok, listed = pcall(function()
                unfinished.seeded("multiply.py", "def f(x):\n    pass")
                spit(tmp .. "/multiply.py", "def f(x):\n    return x * 2")
                spit(tmp .. "/multiply.py.bak", "def f(x):\n    return x * 3")
                spit(tmp .. "/kata.bak", "work")
                return vim.tbl_map(function(e) return e.file end, unfinished.list({}))
            end)
            config.langs = saved_langs
            assert(ok, listed)

            assert.same({ "multiply.py" }, listed)
        end)
    end)
end)
