--- The stash exists so a dirty close cannot lose work. Its one hard promise:
--- a path comes back ONLY when the bytes actually landed. Before this, a
--- failed write returned a path anyway, the workspace logged "stashed", and
--- then force-deleted the buffers.
local real_utils = package.loaded["codewars.cache.utils"]

--- Re-require the stash with a stubbed cache-utils (it binds at load).
local function load_stash(write_ok)
    local written = {}
    package.loaded["codewars.cache.utils"] = {
        cache_file = function(name)
            return {
                absolute = function() return "/tmp/" .. name end,
                exists = function() return write_ok end,
                rm = function() return true end,
            }
        end,
        write_json = function(_, data)
            written[#written + 1] = data
            return write_ok, write_ok and nil or "disk full"
        end,
        read_json = function() return nil end,
    }
    package.loaded["codewars.cache.stash"] = nil
    local mod = require("codewars.cache.stash")
    package.loaded["codewars.cache.stash"] = nil
    return mod, written
end

--- plenary registers hooks against the enclosing describe; a top-level
--- after_each has no block to attach to and kills the whole file, which then
--- reports NO tally at all -- invisible to any check that only sums results.
local function cleanup()
    package.loaded["codewars.cache.utils"] = real_utils
    package.loaded["codewars.cache.stash"] = nil
end

describe("cache.stash", function()
    after_each(cleanup)

    it("returns a path when the write lands", function()
        local stash = load_stash(true)
        local path = stash.for_kind("kumite-stash-").save({ id = "abc", code = "x" })
        assert.are.equal("/tmp/kumite-stash-abc.json", path)
    end)

    it("returns NIL when the write fails, so the caller cannot claim success", function()
        local stash = load_stash(false)
        local path = stash.for_kind("kumite-stash-").save({ id = "abc", code = "x" })
        assert.is_nil(path, "a failed write must never look like a successful stash")
    end)

    it("stamps saved_at in UTC and keeps the entry intact", function()
        local stash, written = load_stash(true)
        stash.for_kind("kata-stash-").save({ id = "k1", name = "musti" })
        assert.are.equal(1, #written)
        assert.are.equal("musti", written[1].name)
        assert.truthy(written[1].saved_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))
    end)

    it("keeps kinds in separate files", function()
        local stash, written = load_stash(true)
        local kumite = stash.for_kind("kumite-stash-").save({ id = "same" })
        local kata = stash.for_kind("kata-stash-").save({ id = "same" })
        assert.are_not.equal(kumite, kata)
        assert.are.equal(2, #written)
    end)
end)
