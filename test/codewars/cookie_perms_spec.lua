-- The cookie file holds a live _session_id and CSRF token: whoever can read
-- it can act as the signed-in user on codewars.com. It was written with the
-- default file mode (0666 minus the umask, usually 0644), which lets every
-- other local account read it. Lua has no octal literals, so the modes below
-- are decimal: 384 is 0600, 420 is 0644, 438 is 0666, 511 is 0777, and
-- 128 is 0200.
describe("Cookie file permissions", function()
    local Path = require("plenary.path")
    local bit = require("bit")
    local real_utils = package.loaded["codewars.cache.utils"]
    local real_menu = package.loaded["codewars-ui.renderer.menu"]
    local real_fs_open = vim.loop.fs_open
    local real_fs_write = vim.loop.fs_write
    local real_fs_fchmod = vim.loop.fs_fchmod
    local real_fs_close = vim.loop.fs_close
    local OWNER_ONLY = 384
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
        vim.loop.fs_open = real_fs_open
        vim.loop.fs_write = real_fs_write
        vim.loop.fs_fchmod = real_fs_fchmod
        vim.loop.fs_close = real_fs_close
        package.loaded["codewars-ui.renderer.menu"] = real_menu
        package.loaded["codewars.cache.utils"] = real_utils
        package.loaded["codewars.cache.cookie"] = nil
    end)

    -- Whether this holds without the fix depends on the umask the spec runs
    -- under (a umask of 077 gives 0600 for free), so the tests below check
    -- the same thing without leaning on it.
    it("creates the cookie file readable and writable by its owner only", function()
        assert.is_nil(Cookie.set("CSRF-TOKEN=abc; _session_id=xyz"))

        assert.equals(OWNER_ONLY, mode_of(path))
    end)

    it("sets the owner-only mode on the file it writes before any of the cookie goes in", function()
        local str = "CSRF-TOKEN=abc; _session_id=xyz"
        local events = {}
        vim.loop.fs_fchmod = function(fd, mode, ...)
            events[#events + 1] = { op = "fchmod", fd = fd, mode = mode }
            return real_fs_fchmod(fd, mode, ...)
        end
        vim.loop.fs_write = function(fd, data, ...)
            if data == str then events[#events + 1] = { op = "write", fd = fd } end
            return real_fs_write(fd, data, ...)
        end

        assert.is_nil(Cookie.set(str))

        assert.equals(2, #events)
        assert.equals("fchmod", events[1].op)
        assert.equals(OWNER_ONLY, events[1].mode)
        assert.equals("write", events[2].op)
        -- The mode has to land on the file that is written, not on whatever
        -- the path names a moment later.
        assert.equals(events[1].fd, events[2].fd)
    end)

    it("tightens a cookie file an older version left world-readable", function()
        precreate(420, "CSRF-TOKEN=old; _session_id=old")

        assert.is_nil(Cookie.set("CSRF-TOKEN=abc; _session_id=xyz"))

        assert.equals(OWNER_ONLY, mode_of(path))
        assert.equals("xyz", Cookie.get().session_id)
    end)

    it("removes the group and other write bits from a 0666 file too", function()
        precreate(438, "CSRF-TOKEN=old; _session_id=old")

        assert.is_nil(Cookie.set("CSRF-TOKEN=abc; _session_id=xyz"))

        assert.equals(OWNER_ONLY, mode_of(path))
    end)

    it("keeps the file private when the cookie is set from its two parts", function()
        precreate(420, "CSRF-TOKEN=old; _session_id=old")

        assert.is_nil(Cookie.set_parts("abc", "xyz"))

        assert.equals(OWNER_ONLY, mode_of(path))
    end)

    it("restricts an existing file before the new cookie is written into it", function()
        precreate(420, "CSRF-TOKEN=old; _session_id=old")
        local str = "CSRF-TOKEN=abc; _session_id=xyz"
        local seen = {}
        vim.loop.fs_write = function(fd, data, ...)
            if data == str then
                local stat = vim.loop.fs_fstat(fd)
                seen[#seen + 1] = bit.band(stat.mode, 511)
            end
            return real_fs_write(fd, data, ...)
        end

        assert.is_nil(Cookie.set(str))

        assert.are.same({ OWNER_ONLY }, seen)
    end)

    -- Another Neovim running an older plugin can create the file after this
    -- one has looked and found nothing there. The mode has to be set on the
    -- file that actually gets opened, not on one the path named earlier.
    it("restricts a world-readable file that appears just before the write", function()
        local str = "CSRF-TOKEN=abc; _session_id=xyz"
        local mode_when_written
        vim.loop.fs_open = function(p, flags, mode, ...)
            if p == path then
                -- Restored first: the call below must reach the real one.
                vim.loop.fs_open = real_fs_open
                precreate(420, "CSRF-TOKEN=old; _session_id=old")
            end
            return real_fs_open(p, flags, mode, ...)
        end
        vim.loop.fs_write = function(fd, data, ...)
            if data == str then mode_when_written = bit.band(vim.loop.fs_fstat(fd).mode, 511) end
            return real_fs_write(fd, data, ...)
        end

        assert.is_nil(Cookie.set(str))

        assert.equals(OWNER_ONLY, mode_when_written)
        assert.equals(OWNER_ONLY, mode_of(path))
    end)

    -- A umask is subtracted from the mode a file is created with, so one
    -- that removes the owner's write bit would leave a 0400 file the next
    -- save cannot open. Simulate it: the umask cannot be set from Lua.
    it("still ends with an owner-writable file when the umask strips write on creation", function()
        vim.loop.fs_open = function(p, flags, mode, ...)
            if p == path and mode then mode = bit.band(mode, bit.bnot(128)) end
            return real_fs_open(p, flags, mode, ...)
        end

        assert.is_nil(Cookie.set("CSRF-TOKEN=abc; _session_id=xyz"))

        assert.equals(OWNER_ONLY, mode_of(path))
        assert.is_nil(Cookie.set("CSRF-TOKEN=def; _session_id=uvw"))
        assert.equals("uvw", Cookie.get().session_id)
    end)

    -- Better no cookie than one in a file that could not be locked down, and
    -- never a leaked descriptor.
    it("writes nothing and closes the file when the mode cannot be set", function()
        local str = "CSRF-TOKEN=abc; _session_id=xyz"
        local opened, closed, wrote = nil, {}, false
        vim.loop.fs_open = function(p, ...)
            local fd, err, name = real_fs_open(p, ...)
            if p == path then opened = fd end
            return fd, err, name
        end
        vim.loop.fs_fchmod = function() return nil, "EPERM: operation not permitted" end
        vim.loop.fs_write = function(fd, data, ...)
            if data == str then wrote = true end
            return real_fs_write(fd, data, ...)
        end
        vim.loop.fs_close = function(fd, ...)
            closed[#closed + 1] = fd
            return real_fs_close(fd, ...)
        end

        local ok, err = pcall(Cookie.set, str)

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("EPERM", 1, true))
        assert.is_false(wrote)
        assert.are.same({ opened }, closed)
    end)

    it("makes the file private before the menu is told about the new session", function()
        precreate(420, "CSRF-TOKEN=old; _session_id=old")
        local mode_when_told
        package.loaded["codewars-ui.renderer.menu"] = {
            session_changed = function() mode_when_told = mode_of(path) end,
        }

        assert.is_nil(Cookie.set("CSRF-TOKEN=abc; _session_id=xyz"))

        assert.equals(OWNER_ONLY, mode_when_told)
    end)

    it("leaves the file alone when the cookie is rejected", function()
        precreate(420, "CSRF-TOKEN=old; _session_id=old")

        assert.is_truthy(Cookie.set("not a cookie"))

        assert.equals(420, mode_of(path))
        assert.equals("old", Cookie.get().session_id)
    end)
end)
