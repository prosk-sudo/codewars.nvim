-- The other half of the in-place write: <path>.bak is the previous cache while
-- a write is under way. If a restore failed or the editor died mid-write, the
-- next read finds it and either recovers from it or clears it away. It is also
-- never mistaken for a cache entry by the scans, and goes with its cache when
-- the cache is deleted.
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
            spit(bak, good)

            assert.same({ kept = "yes" }, read())

            assert.equals(good, slurp(file), "the backup was not written back")
            assert.is_nil(uv.fs_stat(bak))
            assert.equals(1, #warnings, vim.inspect(warnings))
        end)

        it("recovers from the backup when the file is empty", function()
            spit(file, "")
            spit(bak, good)

            assert.same({ kept = "yes" }, read())
            assert.equals(good, slurp(file))
            assert.is_nil(uv.fs_stat(bak))
        end)

        it("recovers from the backup when the file is missing, with the backup's permission bits", function()
            spit(bak, good)
            uv.fs_chmod(bak, 384) -- 0600

            assert.same({ kept = "yes" }, read())

            assert.equals(good, slurp(file))
            assert.equals(384, bit.band(uv.fs_stat(file).mode, 511))
            assert.is_nil(uv.fs_stat(bak))
        end)

        it("says so once, not on every read", function()
            spit(file, "")
            spit(bak, good)

            read()
            read()

            assert.equals(1, #warnings, vim.inspect(warnings))
        end)

        it("clears a stale backup away when the file decodes fine", function()
            spit(file, vim.json.encode({ kept = "newer" }))
            spit(bak, good)

            assert.same({ kept = "newer" }, read())

            assert.is_nil(uv.fs_stat(bak), "a stale backup was left behind")
            assert.same({}, warnings)
        end)

        it("does not use a backup that does not decode either", function()
            spit(file, "{ torn")
            spit(bak, "{ also torn")

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
            assert.is_nil(uv.fs_stat(file .. ".bak"))
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
            spit(file .. ".bak", vim.json.encode({ back = true }))

            vim.fn.delete(file)
            backup.drop(P:new(file))

            assert.is_nil(uv.fs_stat(file .. ".bak"))
            assert.is_nil(cache_utils.read_json(P:new(file)))
        end)

        it("drops a backup that has no cache beside it just the same", function()
            local backup = require("codewars.cache.backup")
            local file = tmp .. "/gone.json"
            spit(file .. ".bak", "{}")

            backup.drop(P:new(file))

            assert.is_nil(uv.fs_stat(file .. ".bak"))
        end)

        it("does not bring a deleted stash back", function()
            local stash = require("codewars.cache.stash").for_kind("t-stash-")
            local path = assert(stash.save({ id = "k1", code = "x" }))
            spit(path .. ".bak", vim.json.encode({ id = "k1", code = "old" }))

            assert.is_true(stash.delete("k1"))

            assert.is_nil(stash.get("k1"))
            assert.is_nil(uv.fs_stat(path .. ".bak"))
        end)

        it("does not bring a deleted session back", function()
            local session = require("codewars.cache.session")
            sessions_dir()
            session.save("two-sum", "python", { solutionId = "s1" })
            local path = cache_utils.cache_file("sessions"):joinpath("two-sum_python.json"):absolute()
            spit(path .. ".bak", vim.json.encode({ solutionId = "s0", cached_at = os.time() }))

            session.delete("two-sum", "python")

            assert.is_nil(session.get("two-sum", "python"))
            assert.is_nil(uv.fs_stat(path .. ".bak"))
        end)

        it("does not bring back a cleared profile", function()
            local profile = require("codewars.cache.profile")
            local path = cache_utils.cache_file("profile.json"):absolute()
            spit(path, "{}")
            spit(path .. ".bak", vim.json.encode({ username = "old" }))

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
            spit(dir .. "/a_python.json.bak", "{}")
            spit(dir .. "/orphan_python.json.bak", "{}")

            assert.equals(2, session.clear_all())

            assert.same({}, vim.fn.readdir(dir), "a backup survived clear_all, and would bring a session back")
        end)

        it("session.count counts sessions, not their backups", function()
            local session = require("codewars.cache.session")
            local dir = sessions_dir()
            session.save("a", "python", { solutionId = "1" })
            spit(dir .. "/a_python.json.bak", "{}")
            spit(dir .. "/orphan_python.json.bak", "{}")

            assert.equals(1, session.count())
        end)

        it("unfinished.list does not list a solution's backup or the record's", function()
            local unfinished = require("codewars.unfinished")
            local saved_langs = config.langs
            -- A language whose files end in .bak: the only way a backup could be
            -- mistaken for a solution by the extension alone.
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
