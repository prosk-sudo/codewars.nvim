-- The cookie file holds a live _session_id and CSRF token: whoever can read
-- it can act as the signed-in user on codewars.com. It was written with the
-- default file mode (0666 minus the umask, usually 0644), which lets every
-- other local account read it. Lua has no octal literals, so the modes below
-- are decimal: 384 is 0600, 420 is 0644, 438 is 0666, 511 is 0777, 256 is
-- 0400 and 128 is 0200.
describe("Cookie file permissions", function()
    local Path = require("plenary.path")
    local bit = require("bit")
    local real_utils = package.loaded["codewars.cache.utils"]
    local real_menu = package.loaded["codewars-ui.renderer.menu"]
    local OWNER_ONLY = 384
    local OLD = "CSRF-TOKEN=old; _session_id=old"
    local STR = "CSRF-TOKEN=abc; _session_id=xyz"

    -- The libuv calls these tests wrap to watch or break the save.
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

    -- A file as an older version of the plugin left it, whatever the
    -- umask of the machine running this spec.
    local function precreate(mode, contents)
        Path:new(path):write(contents, "w")
        assert(vim.loop.fs_chmod(path, mode))
    end

    -- The cookie is saved through a temporary file next to it, so anything
    -- other than the cookie itself in the directory is a leftover.
    local function is_temporary(p)
        return p ~= path and p:sub(1, #path) == path
    end

    before_each(function()
        -- Keyed by name: Cookie.set's identity_changed() clears the other
        -- cache files through cache_file(), and one shared path would
        -- delete the cookie that was just written.
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

    -- Whether this holds without the fix depends on the umask the spec runs
    -- under (a umask of 077 gives 0600 for free), so the tests below check
    -- the same thing without leaning on it.
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
        -- The mode has to land on the file that is written, not on whatever
        -- the path names a moment later.
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

    -- Opening a read-only file for writing is refused, so a save that
    -- reopened the old file could never get as far as making it writable.
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

    -- Another Neovim running an older plugin can create the file while this
    -- one is saving. The cookie goes into a file of its own and replaces
    -- whatever is at the path, so it never lands in the one that appeared.
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

    -- A umask is subtracted from the mode a file is created with, so one
    -- that removes the owner's write bit would leave a 0400 file the next
    -- save cannot open. Simulate it: the umask cannot be set from Lua.
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

    -- Exclusive creation: a file that already has the temporary name was not
    -- made by this save, and writing into it would put the cookie wherever
    -- that file's mode and owner say.
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

    -- Better the old session than none, and never a leaked descriptor or a
    -- half-written file next to the cookie. A saved session is only replaced
    -- once the new one is complete.
    for _, step in ipairs({ "fs_fchmod", "fs_write", "fs_rename" }) do
        it(("keeps the saved cookie, closes the file and leaves no temporary file when %s fails"):format(step), function()
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
            vim.loop[step] = function() return nil, "EIO: i/o error" end

            local ok, err = pcall(Cookie.set, STR)
            restore()

            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("EIO", 1, true))
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
