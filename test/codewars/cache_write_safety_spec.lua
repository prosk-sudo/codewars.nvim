-- A cache write that fails partway must leave the previous cache as it was: the old bytes go to <path>.bak,
-- the file is rewritten in place (keeping its owner, mode and ACLs), and the copy is put back on failure.
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

local function perms(path)
    local stat = uv.fs_stat(path)
    return stat and bit.band(stat.mode, 511)
end

describe("cache.utils write_json keeps the previous cache when a write fails", function()
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local cache_utils = require("codewars.cache.utils")
    local saved_storage, real_error, real_warn, real_write, errors
    local tmp, file, bak, original, fresh, payload

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved_storage, real_error, real_warn, real_write, errors = config.storage, log.error, log.warn, uv.fs_write, {}
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        log.error = function(msg) errors[#errors + 1] = tostring(msg) end
        log.warn = function() end
        file, bak = tmp .. "/cache.json", tmp .. "/cache.json.bak"
        original = vim.json.encode({ old = string.rep("o", 300) })
        fresh = { fresh = string.rep("n", 600) }
        payload = vim.json.encode(fresh)
    end)

    after_each(function()
        uv.fs_write = real_write
        config.storage, log.error, log.warn = saved_storage, real_error, real_warn
        pcall(uv.fs_chmod, file, 420)
        vim.fn.delete(tmp, "rf")
    end)

    local function write() return cache_utils.write_json(P:new(file), fresh) end

    --- A disk that fills up while `payload` is being written: half of it lands.
    local function disk_full_on(bytes, also_after)
        local failed = false
        uv.fs_write = function(fd, data, offset)
            if data == bytes then
                failed = true
                real_write(fd, data:sub(1, math.floor(#data / 2)), offset)
                return nil, "ENOSPC: no space left on device"
            end
            if failed and also_after and data == also_after then
                return nil, "ENOSPC: no space left on device"
            end
            return real_write(fd, data, offset)
        end
    end

    it("restores the original byte for byte when the write fails halfway, and reports it", function()
        spit(file, original)
        disk_full_on(payload)

        local ok, err = write()

        assert.is_false(ok)
        assert.matches("ENOSPC", err)
        assert.equals(original, slurp(file))
        assert.is_nil(uv.fs_stat(bak), "a backup was left behind")
        assert.equals(1, #errors, vim.inspect(errors))
    end)

    it("leaves no partial file when a new file fails halfway", function()
        disk_full_on(payload)

        local ok, err = write()

        assert.is_false(ok)
        assert.matches("ENOSPC", err)
        assert.is_nil(uv.fs_stat(file), "a partial cache was left behind")
        assert.is_nil(uv.fs_stat(bak))
    end)

    it("replaces the content in place: same inode, no backup left", function()
        spit(file, original)
        local before = uv.fs_stat(file)

        assert.is_true((write()))

        assert.same(fresh, vim.json.decode(slurp(file)))
        assert.equals(before.ino, uv.fs_stat(file).ino)
        assert.is_nil(uv.fs_stat(bak))
    end)

    for _, mode in ipairs({ 384, 416, 438 }) do -- 0600, 0640, 0666
        it(("backs the original up with its own permission bits (%o) while it writes"):format(mode), function()
            spit(file, original)
            uv.fs_chmod(file, mode)
            local seen
            uv.fs_write = function(fd, data, offset)
                if data == payload then
                    seen = { mode = perms(bak), text = payload_of(bak) }
                end
                return real_write(fd, data, offset)
            end

            assert.is_true((write()))

            assert.is_table(seen, "no backup existed while the file was being rewritten")
            assert.equals(mode, seen.mode)
            assert.equals(original, seen.text)
            assert.equals(mode, perms(file))
        end)
    end

    it("reports a read-only original, leaves it untouched and leaves no backup", function()
        spit(file, original)
        uv.fs_chmod(file, 256) -- 0400
        if uv.fs_access(file, "W") then return pending("running as a user that ignores file modes") end

        local ok, err = write()

        assert.is_false(ok)
        assert.is_string(err)
        assert.equals(original, slurp(file))
        assert.equals(256, perms(file))
        assert.is_nil(uv.fs_stat(bak))
        assert.equals(1, #errors, vim.inspect(errors))
    end)

    it("keeps the backup, and says so, when the original cannot be put back either", function()
        spit(file, original)
        disk_full_on(payload, original)

        local ok, err = write()

        assert.is_false(ok)
        assert.matches("ENOSPC", err)
        assert.matches(vim.pesc(bak), err)
        assert.equals(original, payload_of(bak), "the backup must hold the previous cache in full")
        assert.equals(1, #errors, vim.inspect(errors))
    end)

    it("keeps writing after a short write", function()
        spit(file, original)
        uv.fs_write = function(fd, data, offset)
            if data == payload then
                local half = math.floor(#data / 2)
                return real_write(fd, data:sub(1, half), offset)
            end
            return real_write(fd, data, offset)
        end

        assert.is_true((write()))

        assert.equals(payload, slurp(file))
        assert.is_nil(uv.fs_stat(bak))
    end)

    it("counts a write of zero bytes as a failure and restores the original", function()
        spit(file, original)
        uv.fs_write = function(fd, data, offset)
            if data == payload then return 0 end
            return real_write(fd, data, offset)
        end

        local ok, err = write()

        assert.is_false(ok)
        assert.is_string(err)
        assert.equals(original, slurp(file))
        assert.is_nil(uv.fs_stat(bak))
    end)

    it("touches nothing when the data cannot be encoded", function()
        spit(file, original)
        local before = uv.fs_stat(file)

        local ok, err = cache_utils.write_json(P:new(file), { oops = function() end })

        assert.is_false(ok)
        assert.is_string(err)
        assert.equals(original, slurp(file))
        assert.equals(before.mtime.nsec, uv.fs_stat(file).mtime.nsec)
        assert.is_nil(uv.fs_stat(bak))
    end)

    it("recovers a leftover backup before writing over a damaged cache, so a second failure cannot lose it", function()
        spit(file, "{ torn")
        put(bak, original)
        disk_full_on(payload)

        local ok = write()

        assert.is_false(ok)
        assert.equals(original, slurp(file), "the good backup was overwritten by the damaged file")
    end)
end)
