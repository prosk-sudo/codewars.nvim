-- A backup is trusted only if its `CWBAK1 <byte-length> <sha256-hex>` header, length and checksum match and the
-- payload decodes: a crash can leave a prefix that is itself valid JSON.
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

--- A backup of `payload`, built here so that the spec states the format and not the code's idea of it.
local function frame(payload)
    return ("CWBAK1 %d %s\n%s"):format(#payload, vim.fn.sha256(payload), payload)
end

describe("cache backup format", function()
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local cache_utils = require("codewars.cache.utils")
    local saved_storage, real_warn, real_error, real_write
    local tmp, file, bak, payload

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved_storage, real_warn, real_error, real_write = config.storage, log.warn, log.error, uv.fs_write
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        log.warn, log.error = function() end, function() end
        file, bak = tmp .. "/cache.json", tmp .. "/cache.json.bak"
        payload = vim.json.encode({ kept = "yes", more = string.rep("m", 40) })
    end)

    after_each(function()
        config.storage, log.warn, log.error, uv.fs_write = saved_storage, real_warn, real_error, real_write
        vim.fn.delete(tmp, "rf")
    end)

    local function read() return cache_utils.read_json(P:new(file)) end

    --- The cache is damaged, and `bak` holds `bytes`: what does a read recover?
    local function recovered_from(bytes)
        spit(file, "{ torn")
        spit(bak, bytes)
        local data = read()
        return data, slurp(file)
    end

    it("recovers from a complete backup, writing back the payload and no header", function()
        local data, main = recovered_from(frame(payload))

        assert.same({ kept = "yes", more = string.rep("m", 40) }, data)
        assert.equals(payload, main)
        assert.is_nil(main:find("CWBAK1", 1, true))
    end)

    it("recovers nothing from a backup cut short at any length", function()
        local full = frame(payload)
        for n = 0, #full - 1 do
            local data, main = recovered_from(full:sub(1, n))
            assert.is_nil(data, ("a backup cut at %d of %d bytes was recovered"):format(n, #full))
            assert.equals("{ torn", main)
        end
    end)

    it("recovers nothing from any cut of a backup whose payload is valid JSON in every prefix", function()
        local number = "1234567890123456" -- every prefix of it decodes
        local full = frame(number)
        for n = 0, #full - 1 do
            local data = recovered_from(full:sub(1, n))
            assert.is_nil(data, ("a backup cut at %d of %d bytes was recovered"):format(n, #full))
        end
        assert.equals(1234567890123456, (recovered_from(full)))
    end)

    it("recovers nothing when a payload byte was flipped", function()
        local full = frame(payload)
        local at = full:find("yes", 1, true)
        local flipped = full:sub(1, at - 1) .. "no!" .. full:sub(at + 3) -- still valid JSON, same length

        local data = recovered_from(flipped)

        assert.is_nil(data)
    end)

    it("recovers nothing when the header names the wrong length", function()
        for _, wrong in ipairs({ #payload + 1, #payload - 1, 0 }) do
            local text = ("CWBAK1 %d %s\n%s"):format(wrong, vim.fn.sha256(payload), payload)
            assert.is_nil((recovered_from(text)), "a length of " .. wrong .. " was accepted")
        end
    end)

    it("recovers nothing when the checksum is of something else", function()
        local text = ("CWBAK1 %d %s\n%s"):format(#payload, vim.fn.sha256(payload .. " "), payload)
        assert.is_nil((recovered_from(text)))
    end)

    it("recovers nothing from a file with no header: an old backup, or plain JSON", function()
        assert.is_nil((recovered_from(payload)))
    end)

    it("recovers nothing from a garbled header", function()
        local sha = vim.fn.sha256(payload)
        for _, header in ipairs({
            ("CWBAK2 %d %s"):format(#payload, sha),
            ("cwbak1 %d %s"):format(#payload, sha),
            ("CWBAK1  %d %s"):format(#payload, sha),
            ("CWBAK1 %d"):format(#payload),
            ("CWBAK1 x %s"):format(sha),
            ("CWBAK1 %d %s"):format(#payload, sha:sub(1, 63) .. "g"),
            ("CWBAK1 %d %s extra"):format(#payload, sha),
            "",
        }) do
            assert.is_nil((recovered_from(header .. "\n" .. payload)), "accepted the header: " .. header)
        end
    end)

    it("recovers nothing from a header with no newline after it", function()
        assert.is_nil((recovered_from(("CWBAK1 %d %s"):format(#payload, vim.fn.sha256(payload)))))
    end)

    it("recovers nothing from a complete backup whose payload does not decode", function()
        assert.is_nil((recovered_from(frame("1234garbage"))))
    end)

    it("recovers nothing from an empty backup", function()
        assert.is_nil((recovered_from("")))
    end)

    it("writes the backup as the header followed by the original bytes, and puts the original back exactly", function()
        local original = vim.json.encode({ old = string.rep("o", 300) })
        local fresh = { fresh = string.rep("f", 600) }
        local new_bytes = vim.json.encode(fresh)
        spit(file, original)
        local seen
        local real = uv.fs_write
        uv.fs_write = function(fd, data, offset)
            if data == new_bytes then
                seen = slurp(bak)
                real(fd, data:sub(1, 100), offset)
                return nil, "ENOSPC: no space left on device"
            end
            return real(fd, data, offset)
        end

        local ok = cache_utils.write_json(P:new(file), fresh, { quiet = true })

        uv.fs_write = real
        assert.is_false(ok)
        assert.equals(frame(original), seen, "the backup is not a header line followed by the original bytes")
        assert.equals(original, slurp(file), "the restore did not write back exactly the original bytes")
        assert.is_nil(slurp(file):find("CWBAK1", 1, true), "the header was written into the cache")
        assert.is_nil(uv.fs_lstat(bak))
    end)

    describe("a crash while the backup is being created", function()
        --- A fresh Neovim whose write of the backup dies, with no clean-up, after `n` bytes.
        local function crash_after(n, main_text)
            local script = tmp .. "/child.lua"
            spit(script, ([[
vim.opt.rtp:prepend(%s)
local uv = vim.uv or vim.loop
local backup = require("codewars.cache.backup")
local function parse(t) local ok, d = pcall(vim.json.decode, t); return ok and d or nil end
local f = assert(io.open(%s, "wb")); f:write(%s); f:close()
local real_open, real_write = uv.fs_open, uv.fs_write
local fds = {}
uv.fs_open = function(path, flags, mode)
    local fd, err, name = real_open(path, flags, mode)
    if fd and path == %s then fds[fd] = true end
    return fd, err, name
end
uv.fs_write = function(fd, data, offset)
    if fds[fd] then
        real_write(fd, data:sub(1, %d), offset)
        os.exit(3) -- the process dies: nothing is cleaned up
    end
    return real_write(fd, data, offset)
end
backup.write(%s, "{}", parse)
]]):format(vim.inspect(vim.fn.getcwd()), vim.inspect(file), vim.inspect(main_text), vim.inspect(bak), n,
                vim.inspect(file)))
            return vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-c", "luafile " .. script, "-c", "qa!" },
                { timeout = 10000, text = true }):wait()
        end

        for _, n in ipairs({ 0, 1, 4, 12, 30, 50 }) do
            it(("leaves nothing that is recovered as the cache (cut after %d bytes)"):format(n), function()
                if not vim.system then return pending("needs vim.system (Neovim 0.10)") end

                local res = crash_after(n, "1234garbage")

                assert.equals(3, res.code, "the child did not crash where it was meant to: " .. tostring(res.stderr))
                assert.is_not_nil(uv.fs_lstat(bak), "the crash left no backup, so it proves nothing")
                assert.is_nil(read(), "a crash-cut backup was recovered as the cache")
                assert.equals("1234garbage", slurp(file))
            end)
        end
    end)
end)
