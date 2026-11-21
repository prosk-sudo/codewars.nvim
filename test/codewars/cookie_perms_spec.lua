-- The cookie file holds a live _session_id and CSRF token: whoever can read
-- it can act as the signed-in user on codewars.com. It was written with the
-- default file mode (0666 minus the umask, usually 0644), which lets every
-- other local account read it. Lua has no octal literals, so the modes below
-- are decimal: 384 is 0600, 420 is 0644, 438 is 0666, 511 is 0777.
describe("Cookie file permissions", function()
    local Path = require("plenary.path")
    local bit = require("bit")
    local real_utils = package.loaded["codewars.cache.utils"]
    local real_menu = package.loaded["codewars-ui.renderer.menu"]
    local real_fs_write = vim.loop.fs_write
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
        vim.loop.fs_write = real_fs_write
        package.loaded["codewars-ui.renderer.menu"] = real_menu
        package.loaded["codewars.cache.utils"] = real_utils
        package.loaded["codewars.cache.cookie"] = nil
    end)

    it("creates the cookie file readable and writable by its owner only", function()
        assert.is_nil(Cookie.set("CSRF-TOKEN=abc; _session_id=xyz"))

        assert.equals(OWNER_ONLY, mode_of(path))
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
