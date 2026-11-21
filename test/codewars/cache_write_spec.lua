-- A caller that reports a failed cache write itself, once and in its own
-- words, asks write_json not to log one more line per failure. And a cache is
-- replaced whole or not at all: a write that fails halfway (a full disk) must
-- leave the cache that was there, not an empty or partial file in its place.
local P = require("plenary.path")

describe("cache.utils write_json", function()
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local cache_utils = require("codewars.cache.utils")
    local uv = vim.uv or vim.loop
    local saved_storage, real_error, errors, tmp

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved_storage, real_error, errors = config.storage, log.error, {}
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        log.error = function(msg) errors[#errors + 1] = tostring(msg) end
    end)

    after_each(function()
        config.storage, log.error = saved_storage, real_error
        vim.fn.delete(tmp, "rf")
    end)

    local function unwritable() return P:new(tmp .. "/no/such/dir/file.json") end

    --- The names in the cache directory.
    local function listing()
        local names = {}
        for name in vim.fs.dir(tmp) do names[#names + 1] = name end
        table.sort(names)
        return names
    end

    local function bytes(path)
        local fd = assert(uv.fs_open(path, "r", 438))
        local stat = assert(uv.fs_fstat(fd))
        local text = assert(uv.fs_read(fd, stat.size, 0))
        uv.fs_close(fd)
        return text
    end

    it("reports a write that did not land, and says why in the log", function()
        local ok, err = cache_utils.write_json(unwritable(), { a = 1 })
        assert.is_false(ok)
        assert.is_string(err)
        assert.equals(1, #errors, vim.inspect(errors))
    end)

    it("reports it without logging when asked to stay quiet", function()
        local ok, err = cache_utils.write_json(unwritable(), { a = 1 }, { quiet = true })
        assert.is_false(ok)
        assert.is_string(err)
        assert.are.same({}, errors)
    end)

    it("writes as it always did", function()
        local path = P:new(tmp .. "/ok.json")
        assert.is_true((cache_utils.write_json(path, { a = 1 }, { quiet = true })))
        assert.same({ a = 1 }, cache_utils.read_json(path))
    end)

    describe("replaces the file whole, or not at all", function()
        local path, original, real_write, real_rename, real_open, real_fchmod, real_fchown

        before_each(function()
            path = P:new(tmp .. "/cache.json")
            assert.is_true((cache_utils.write_json(path, { items = { "the", "old", "cache" } })))
            original = bytes(path.filename)
            real_write, real_rename = uv.fs_write, uv.fs_rename
            real_open, real_fchmod, real_fchown = uv.fs_open, uv.fs_fchmod, uv.fs_fchown
        end)

        after_each(function()
            uv.fs_write, uv.fs_rename = real_write, real_rename
            uv.fs_open, uv.fs_fchmod, uv.fs_fchown = real_open, real_fchmod, real_fchown
        end)

        --- Make every file the process creates lose the bits of `umask`, as
        --- the OS does: the process umask cannot be changed from Lua.
        ---@param umask integer
        local function with_umask(umask)
            uv.fs_open = function(file, flags, mode, ...)
                return real_open(file, flags, bit.band(mode, bit.bnot(umask)), ...)
            end
        end

        local function mode_of(file) return bit.band(uv.fs_stat(file).mode, tonumber("777", 8)) end

        it("leaves a successful write's file in place and no temp file behind", function()
            assert.is_true((cache_utils.write_json(path, { items = { "new" } })))
            assert.same({ items = { "new" } }, cache_utils.read_json(path))
            assert.are.same({ "cache.json" }, listing())
        end)

        it("keeps the old file byte for byte, with no temp file, when the disk fills halfway", function()
            -- Some of the bytes land, then there is no room for the rest.
            uv.fs_write = function(fd, data, offset)
                real_write(fd, data:sub(1, 5), offset)
                return nil, "ENOSPC: no space left on device"
            end
            local ok, err = cache_utils.write_json(path, { items = { "new", "much", "longer", "cache" } })
            assert.is_false(ok)
            assert.truthy(tostring(err):find("ENOSPC", 1, true), err)
            assert.equals(original, bytes(path.filename), "the old cache was damaged")
            assert.are.same({ "cache.json" }, listing())
            assert.equals(1, #errors, "failure not logged once")
        end)

        it("reports a short write that makes no progress as a failure, not a stop", function()
            local calls = 0
            uv.fs_write = function(fd, data, offset)
                calls = calls + 1
                if calls == 1 then return real_write(fd, data:sub(1, 3), offset) end -- a short count
                return 0 -- and then nothing
            end
            local ok, err = cache_utils.write_json(path, { items = { "new", "much", "longer", "cache" } }, { quiet = true })
            assert.is_false(ok)
            assert.is_string(err)
            assert.equals(original, bytes(path.filename))
            assert.are.same({ "cache.json" }, listing())
        end)

        it("goes on after a short write until every byte is written", function()
            uv.fs_write = function(fd, data, offset) return real_write(fd, data:sub(1, 4), offset) end
            assert.is_true((cache_utils.write_json(path, { items = { "new", "much", "longer", "cache" } })))
            assert.same({ items = { "new", "much", "longer", "cache" } }, cache_utils.read_json(path))
            assert.are.same({ "cache.json" }, listing())
        end)

        it("keeps the old file, with no temp file, when it cannot be renamed into place", function()
            uv.fs_rename = function() return nil, "EACCES: permission denied" end
            local ok, err = cache_utils.write_json(path, { items = { "new" } }, { quiet = true })
            assert.is_false(ok)
            assert.truthy(tostring(err):find("EACCES", 1, true), err)
            assert.equals(original, bytes(path.filename))
            assert.are.same({ "cache.json" }, listing())
        end)

        it("keeps the old file when the data cannot be encoded", function()
            local ok = cache_utils.write_json(path, { f = function() end }, { quiet = true })
            assert.is_false(ok)
            assert.equals(original, bytes(path.filename))
            assert.are.same({ "cache.json" }, listing())
        end)

        it("keeps the mode the file has", function()
            assert(uv.fs_chmod(path.filename, tonumber("600", 8)))
            assert.is_true((cache_utils.write_json(path, { items = { "new" } })))
            assert.equals(tonumber("600", 8), bit.band(uv.fs_stat(path.filename).mode, tonumber("777", 8)))
        end)

        -- fs_open's mode is masked by the umask again, so a file shared by a
        -- group would lose its group-write bit on every refresh.
        it("keeps a mode the umask would strip bits from", function()
            assert(uv.fs_chmod(path.filename, tonumber("664", 8)))
            with_umask(tonumber("022", 8))
            assert.is_true((cache_utils.write_json(path, { items = { "new" } })))
            assert.equals(tonumber("664", 8), mode_of(path.filename))
            assert.same({ items = { "new" } }, cache_utils.read_json(path))
        end)

        -- A new inode belongs to whoever made it. A cache shared through a
        -- project group has to stay in that group when it is refreshed.
        it("gives the replacement the owner and group of the file it replaces", function()
            local stat = uv.fs_stat(path.filename)
            local given
            uv.fs_fchown = function(fd, uid, gid)
                given = { uid = uid, gid = gid }
                return real_fchown(fd, uid, gid)
            end
            assert.is_true((cache_utils.write_json(path, { items = { "new" } })))
            assert.same({ uid = stat.uid, gid = stat.gid }, given)
        end)

        -- An unprivileged user usually cannot give a file away, and a cache in
        -- one's own cache directory has no one to give it to: when it fails,
        -- the write goes on, mode and all.
        it("goes on with the write when the owner cannot be set", function()
            assert(uv.fs_chmod(path.filename, tonumber("664", 8)))
            uv.fs_fchown = function() return nil, "EPERM: operation not permitted" end
            with_umask(tonumber("022", 8))
            local ok = cache_utils.write_json(path, { items = { "new" } })
            assert.is_true(ok)
            assert.same({ items = { "new" } }, cache_utils.read_json(path))
            assert.equals(tonumber("664", 8), mode_of(path.filename))
            assert.are.same({ "cache.json" }, listing())
            assert.are.same({}, errors, "a best-effort step was logged as an error")
        end)

        it("leaves the owner of a new file to whoever creates it", function()
            uv.fs_fchown = function() error("set the owner of a new file") end
            local fresh = P:new(tmp .. "/fresh.json")
            assert.is_true((cache_utils.write_json(fresh, { a = 1 })))
        end)

        it("keeps the old file, with no temp file, when the mode cannot be set", function()
            assert(uv.fs_chmod(path.filename, tonumber("664", 8)))
            uv.fs_fchmod = function() return nil, "EPERM: operation not permitted" end
            local ok, err = cache_utils.write_json(path, { items = { "new" } }, { quiet = true })
            assert.is_false(ok)
            assert.truthy(tostring(err):find("EPERM", 1, true), err)
            assert.equals(original, bytes(path.filename))
            assert.are.same({ "cache.json" }, listing())
        end)

        it("gives a new file the default mode under the umask, without setting it", function()
            uv.fs_fchmod = function() error("set the mode of a new file") end
            with_umask(tonumber("022", 8))
            local fresh = P:new(tmp .. "/fresh.json")
            assert.is_true((cache_utils.write_json(fresh, { a = 1 })))
            assert.equals(tonumber("644", 8), mode_of(fresh.filename))
        end)

        it("writes through a symlink to the file it points at, as before", function()
            local link = tmp .. "/link.json"
            assert(uv.fs_symlink(path.filename, link))
            assert.is_true((cache_utils.write_json(P:new(link), { items = { "through" } })))
            assert.equals("link", uv.fs_lstat(link).type == "link" and "link" or "replaced")
            assert.same({ items = { "through" } }, cache_utils.read_json(path))
        end)
    end)
end)

-- The completed list is where it matters: a refresh that cannot be written
-- must not take the cache it was refreshing, and the kata marked locally in
-- it, down with it.
describe("completed.update when the cache cannot be written", function()
    local config = require("codewars.config")
    local cache_utils = require("codewars.cache.utils")
    local uv = vim.uv or vim.loop
    local saved, tmp, real_write

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved = {
            storage = config.storage,
            username = config.user.username,
            utils = package.loaded["codewars.api.utils"],
            warn = require("codewars.logger").warn,
            error = require("codewars.logger").error,
        }
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        config.user.username = "me"
        require("codewars.logger").warn = function() end
        require("codewars.logger").error = function() end
        package.loaded["codewars.api.utils"] = {
            get = function(_, opts)
                opts.callback({ data = { { id = "server", slug = "server-kata", completedLanguages = { "java" } } }, totalPages = 1 })
            end,
        }
        real_write = uv.fs_write
    end)

    after_each(function()
        uv.fs_write = real_write
        config.storage, config.user.username = saved.storage, saved.username
        package.loaded["codewars.api.utils"] = saved.utils
        require("codewars.logger").warn, require("codewars.logger").error = saved.warn, saved.error
        vim.fn.delete(tmp, "rf")
    end)

    it("keeps the cache that was there, the kata marked locally in it included", function()
        local completed = require("codewars.cache.completed")
        completed.clear()
        completed.save({
            { id = "old", slug = "old-kata", completedLanguages = { "python" } },
            { id = "mine", slug = "just-solved", completedLanguages = { "python" }, local_mark = true },
        }, os.time() - 90000)
        local file = cache_utils.cache_file("completed.json")
        local before = file:read()

        uv.fs_write = function(fd, data, offset)
            real_write(fd, data:sub(1, 7), offset)
            return nil, "ENOSPC: no space left on device"
        end
        local got
        completed.update(function(items) got = items end)

        assert.same({ "mine", "server" }, vim.tbl_map(function(i) return i.id end, got),
            "the fetched list in memory: the server's kata and the local mark")
        assert.equals(before, file:read(), "the cache on disk was damaged")
        local items, _, fetched = completed.get()
        assert.same({ "old", "mine" }, vim.tbl_map(function(i) return i.id end, items))
        assert.is_true(items[2].local_mark)
        assert.is_true(fetched)
    end)
end)
