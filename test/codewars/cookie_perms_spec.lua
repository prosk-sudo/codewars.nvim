-- The cookie is a live session, so other local accounts must not read it. Modes
-- are decimal: 384 is 0600, 420 is 0644, 438 is 0666, 511 is 0777, 256 is 0400,
-- 128 is 0200.
describe("Cookie file permissions", function()
    local Path = require("plenary.path")
    local bit = require("bit")
    local real_utils = package.loaded["codewars.cache.utils"]
    local real_menu = package.loaded["codewars-ui.renderer.menu"]
    local OWNER_ONLY = 384
    local OLD = "CSRF-TOKEN=old; _session_id=old"
    local STR = "CSRF-TOKEN=abc; _session_id=xyz"

    local WRAPPED = { "fs_open", "fs_write", "fs_fchmod", "fs_close", "fs_rename", "hrtime" }
    local real = {}
    for _, name in ipairs(WRAPPED) do
        real[name] = vim.loop[name]
    end
    local function restore()
        for _, name in ipairs(WRAPPED) do
            vim.loop[name] = real[name]
        end
    end

    local Cookie, dir, path

    local function mode_of(p)
        return bit.band(vim.loop.fs_stat(p).mode, 511)
    end

    -- A file as an older plugin version left it, whatever the machine's umask.
    local function precreate(mode, contents)
        Path:new(path):write(contents, "w")
        assert(vim.loop.fs_chmod(path, mode))
    end

    -- Saves go through a temp file next to the cookie; anything else is a leftover.
    local function is_temporary(p)
        return p ~= path and p:sub(1, #path) == path
    end

    before_each(function()
        -- Keyed by name: Cookie.set clears other cache files, so a shared path
        -- would delete the cookie.
        dir = Path:new(vim.fn.tempname())
        dir:mkdir({ parents = true })
        path = dir:joinpath("cookie"):absolute()
        package.loaded["codewars.cache.utils"] = vim.tbl_extend("force", real_utils or {}, {
            cache_file = function(name) return dir:joinpath(name) end,
        })
        package.loaded["codewars.cache.cookie"] = nil
        Cookie = require("codewars.cache.cookie")
    end)
    after_each(function()
        restore()
        package.loaded["codewars-ui.renderer.menu"] = real_menu
        package.loaded["codewars.cache.utils"] = real_utils
        package.loaded["codewars.cache.cookie"] = nil
    end)

    -- Passes unfixed under a 077 umask, so the tests below do not lean on it.
    it("creates the cookie file readable and writable by its owner only", function()
        assert.is_nil(Cookie.set(STR))

        assert.equals(OWNER_ONLY, mode_of(path))
    end)

    it("sets the owner-only mode on the file it writes before any of the cookie goes in", function()
        local events = {}
        vim.loop.fs_fchmod = function(fd, mode, ...)
            events[#events + 1] = { op = "fchmod", fd = fd, mode = mode }
            return real.fs_fchmod(fd, mode, ...)
        end
        vim.loop.fs_write = function(fd, data, ...)
            if data == STR then events[#events + 1] = { op = "write", fd = fd } end
            return real.fs_write(fd, data, ...)
        end

        assert.is_nil(Cookie.set(STR))

        assert.equals(2, #events)
        assert.equals("fchmod", events[1].op)
        assert.equals(OWNER_ONLY, events[1].mode)
        assert.equals("write", events[2].op)
        -- The mode must land on the file being written, not whatever the path names.
        assert.equals(events[1].fd, events[2].fd)
    end)

    it("tightens a cookie file an older version left world-readable", function()
        precreate(420, OLD)

        assert.is_nil(Cookie.set(STR))

        assert.equals(OWNER_ONLY, mode_of(path))
        assert.equals("xyz", Cookie.get().session_id)
    end)

    it("removes the group and other write bits from a 0666 file too", function()
        precreate(438, OLD)

        assert.is_nil(Cookie.set(STR))

        assert.equals(OWNER_ONLY, mode_of(path))
    end)

    -- A read-only file cannot be opened for writing, so a save that reopens it fails.
    it("replaces a cookie file its owner can only read", function()
        precreate(256, OLD)

        assert.is_nil(Cookie.set(STR))

        assert.equals(OWNER_ONLY, mode_of(path))
        assert.equals("xyz", Cookie.get().session_id)
    end)

    it("keeps the file private when the cookie is set from its two parts", function()
        precreate(420, OLD)

        assert.is_nil(Cookie.set_parts("abc", "xyz"))

        assert.equals(OWNER_ONLY, mode_of(path))
    end)

    it("puts the new cookie in an owner-only file even when a world-readable one was there", function()
        precreate(420, OLD)
        local seen = {}
        vim.loop.fs_write = function(fd, data, ...)
            if data == STR then
                seen[#seen + 1] = bit.band(vim.loop.fs_fstat(fd).mode, 511)
            end
            return real.fs_write(fd, data, ...)
        end

        assert.is_nil(Cookie.set(STR))

        assert.are.same({ OWNER_ONLY }, seen)
    end)

    it("leaves no temporary file behind after a save", function()
        precreate(420, OLD)

        assert.is_nil(Cookie.set(STR))

        local leftovers = vim.tbl_filter(function(name)
            return is_temporary(dir:joinpath(name):absolute())
        end, vim.fn.readdir(dir:absolute()))
        assert.are.same({}, leftovers)
    end)

    -- An older plugin in another Neovim can create the file mid-save; ours replaces it.
    it("replaces a world-readable file that appears while it is saving", function()
        local mode_when_written, raced
        vim.loop.fs_write = function(fd, data, ...)
            if data == STR then mode_when_written = bit.band(vim.loop.fs_fstat(fd).mode, 511) end
            return real.fs_write(fd, data, ...)
        end
        vim.loop.fs_rename = function(...)
            raced = true
            precreate(420, OLD)
            return real.fs_rename(...)
        end

        assert.is_nil(Cookie.set(STR))

        assert.is_true(raced)
        assert.equals(OWNER_ONLY, mode_when_written)
        assert.equals(OWNER_ONLY, mode_of(path))
        assert.equals("xyz", Cookie.get().session_id)
    end)

    -- A umask stripping owner-write at creation would leave a 0400 file. Simulated:
    -- Lua cannot set the umask.
    it("still ends with an owner-writable file when the umask strips write on creation", function()
        vim.loop.fs_open = function(p, flags, mode, ...)
            if is_temporary(p) and mode then mode = bit.band(mode, bit.bnot(128)) end
            return real.fs_open(p, flags, mode, ...)
        end

        assert.is_nil(Cookie.set(STR))

        assert.equals(OWNER_ONLY, mode_of(path))
        assert.is_nil(Cookie.set("CSRF-TOKEN=def; _session_id=uvw"))
        assert.equals("uvw", Cookie.get().session_id)
    end)

    -- Exclusive creation: an existing file at the temp name would keep its own mode.
    it("refuses to write into a file that already has its temporary name", function()
        precreate(420, OLD)
        vim.loop.hrtime = function() return 1 end
        local planted = ("%s.tmp.%d.%.0f"):format(path, vim.loop.os_getpid(), 1)
        Path:new(planted):write("planted", "w")

        local ok = pcall(Cookie.set, STR)
        restore()

        assert.is_false(ok)
        assert.equals("planted", Path:new(planted):read())
        assert.equals(OLD, Path:new(path):read())
    end)

    -- fs_write can store fewer bytes than given. Count only the cookie's text.
    local function is_cookie_text(data)
        return data ~= "" and STR:sub(-#data) == data
    end

    it("writes the whole cookie when the filesystem takes it in pieces", function()
        local calls = 0
        vim.loop.fs_write = function(fd, data, ...)
            if is_cookie_text(data) then
                calls = calls + 1
                data = data:sub(1, 5)
            end
            return real.fs_write(fd, data, ...)
        end

        assert.is_nil(Cookie.set(STR))
        restore()

        assert.is_true(calls > 1)
        assert.equals(STR, Path:new(path):read())
        assert.equals("xyz", Cookie.get().session_id)
    end)

    -- Better the old session than none, and no leaked descriptor or partial file.
    local failures = {
        { step = "fs_fchmod", fails = function() return nil, "EIO: i/o error" end, message = "EIO" },
        { step = "fs_write", fails = function() return nil, "EIO: i/o error" end, message = "EIO" },
        { step = "fs_rename", fails = function() return nil, "EIO: i/o error" end, message = "EIO" },
        -- A call that stores nothing would otherwise be retried for ever.
        { step = "fs_write", fails = function() return 0 end, message = "short write", label = "fs_write stores nothing" },
    }
    for _, failure in ipairs(failures) do
        local label = failure.label or (failure.step .. " fails")
        it(("keeps the saved cookie, closes the file and leaves no temporary file when %s"):format(label), function()
            precreate(420, OLD)
            local opened, closed = {}, {}
            vim.loop.fs_open = function(p, ...)
                local fd, err, name = real.fs_open(p, ...)
                if fd and is_temporary(p) then opened[#opened + 1] = fd end
                return fd, err, name
            end
            vim.loop.fs_close = function(fd, ...)
                closed[#closed + 1] = fd
                return real.fs_close(fd, ...)
            end
            vim.loop[failure.step] = failure.fails

            local ok, err = pcall(Cookie.set, STR)
            restore()

            assert.is_false(ok)
            assert.is_truthy(tostring(err):find(failure.message, 1, true))
            assert.equals(OLD, Path:new(path):read())
            assert.are.same({ "cookie" }, vim.fn.readdir(dir:absolute()))
            assert.equals(1, #opened)
            assert.are.same(opened, closed)
        end)
    end

    it("makes the file private before the menu is told about the new session", function()
        precreate(420, OLD)
        local mode_when_told
        package.loaded["codewars-ui.renderer.menu"] = {
            session_changed = function() mode_when_told = mode_of(path) end,
        }

        assert.is_nil(Cookie.set(STR))

        assert.equals(OWNER_ONLY, mode_when_told)
    end)

    it("leaves the file alone when the cookie is rejected", function()
        precreate(420, OLD)

        assert.is_truthy(Cookie.set("not a cookie"))

        assert.equals(420, mode_of(path))
        assert.equals("old", Cookie.get().session_id)
    end)
end)
