--- The stash exists so a dirty close cannot lose work. Its one hard promise:
--- a path comes back ONLY when the bytes actually landed. Before this, a
--- failed write returned a path anyway, the workspace logged "stashed", and
--- then force-deleted the buffers.
local real_utils = package.loaded["codewars.cache.utils"]
local logger = require("codewars.logger")
local real_warn = logger.warn

--- The stash refuses any id that is not a 24-hex Codewars id (or a local one).
local VALID_ID = "5a1b2c3d4e5f60718293a4b5"

--- Re-require the stash with a stubbed cache-utils (it binds at load).
local function load_stash(write_ok)
    local written = {}
    local files = {}
    package.loaded["codewars.cache.utils"] = {
        cache_file = function(name)
            files[#files + 1] = name
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
    return mod, written, files
end

--- plenary registers hooks against the enclosing describe; a top-level
--- after_each has no block to attach to and kills the whole file, which then
--- reports NO tally at all -- invisible to any check that only sums results.
local function cleanup()
    logger.warn = real_warn
    package.loaded["codewars.cache.utils"] = real_utils
    package.loaded["codewars.cache.stash"] = nil
end

describe("cache.stash", function()
    after_each(cleanup)

    it("returns a path when the write lands", function()
        local stash = load_stash(true)
        local path = stash.for_kind("kumite-stash-").save({ id = VALID_ID, code = "x" })
        assert.are.equal("/tmp/kumite-stash-" .. VALID_ID .. ".json", path)
    end)

    it("returns NIL when the write fails, so the caller cannot claim success", function()
        local stash = load_stash(false)
        local path = stash.for_kind("kumite-stash-").save({ id = VALID_ID, code = "x" })
        assert.is_nil(path, "a failed write must never look like a successful stash")
    end)

    it("stamps saved_at in UTC and keeps the entry intact", function()
        local stash, written = load_stash(true)
        stash.for_kind("kata-stash-").save({ id = VALID_ID, name = "musti" })
        assert.are.equal(1, #written)
        assert.are.equal("musti", written[1].name)
        assert.truthy(written[1].saved_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))
    end)

    it("keeps kinds in separate files", function()
        local stash, written = load_stash(true)
        local kumite = stash.for_kind("kumite-stash-").save({ id = VALID_ID })
        local kata = stash.for_kind("kata-stash-").save({ id = VALID_ID })
        assert.are_not.equal(kumite, kata)
        assert.are.equal(2, #written)
    end)
end)

--- A stash id becomes part of a file name, and it comes from server replies
--- nobody validated. A traversal id used to land the user's buffer contents
--- outside the cache dir.
local MARKER = "stash-escape-probe"

--- The stash on top of the REAL cache utils. minimal_init points the cache dir
--- at a throwaway root, so writing through them is safe here.
local function load_real_stash()
    package.loaded["codewars.cache.utils"] = nil
    package.loaded["codewars.cache.stash"] = nil
    return require("codewars.cache.stash")
end

--- Files named after the marker anywhere under the throwaway root. A stash
--- that escaped the cache dir lands in a sibling directory, so looking only
--- inside the cache dir would miss exactly the bug.
local function files_marked(marker)
    return vim.fn.glob(vim.env.CW_TEST_ROOT .. "/**/*" .. marker .. "*", true, true)
end

describe("cache.stash id validation", function()
    after_each(cleanup)

    it("writes nothing and returns nil for a path-traversal id", function()
        local kumite = load_real_stash().for_kind("kumite-stash-")
        local paths = {}
        for _, id in ipairs({ "../../../" .. MARKER, "x/../../" .. MARKER, "/../" .. MARKER }) do
            paths[#paths + 1] = kumite.save({ id = id, code = "SECRET" })
        end
        assert.are.same({}, files_marked(MARKER), "a stash file escaped the cache dir")
        assert.are.same({}, paths, "a refused id must not look like a successful stash")
    end)

    it("refuses an id that is not exactly 24 hex characters, in save, get and delete", function()
        local bad_ids = {
            "", "abc", 123, {}, ("g"):rep(24), VALID_ID:sub(1, 23), VALID_ID .. "0",
            "../" .. VALID_ID, VALID_ID .. "/..", VALID_ID .. "\n",
            "local-", "local-12a", "local-12/../x", "LOCAL-12",
        }
        for _, id in ipairs(bad_ids) do
            local stash, written, files = load_stash(true)
            local kind = stash.for_kind("kumite-stash-")
            assert.is_nil(kind.save({ id = id, code = "x" }), vim.inspect(id))
            assert.is_nil(kind.get(id), vim.inspect(id))
            assert.is_false(kind.delete(id), vim.inspect(id))
            assert.are.same({}, written, vim.inspect(id))
            assert.are.same({}, files, "no path may even be built for " .. vim.inspect(id))
        end
    end)

    it("refuses an entry with no id instead of raising", function()
        local stash, written = load_stash(true)
        local kind = stash.for_kind("kata-stash-")
        assert.is_nil(kind.save({ code = "x" }))
        assert.is_nil(kind.get(nil))
        assert.is_false(kind.delete(nil))
        assert.are.same({}, written)
    end)

    it("warns when save refuses an id, so the dirty-close path can say why", function()
        local warnings = {}
        logger.warn = function(msg) warnings[#warnings + 1] = msg end
        local stash = load_stash(true)
        stash.for_kind("kumite-stash-").save({ id = "../../etc/passwd", code = "x" })
        assert.are.equal(1, #warnings)
        assert.truthy(warnings[1]:find("passwd", 1, true), "the warning should name the id it refused")
    end)

    it("does not stamp saved_at on an entry it refused", function()
        local stash = load_stash(true)
        local entry = { id = "../x", code = "x" }
        stash.for_kind("kumite-stash-").save(entry)
        assert.is_nil(entry.saved_at)
    end)

    it("still stashes a kumite that was never saved to the server", function()
        -- :CW kumite new gives the draft a "local-<ms>" id until its first
        -- save; a dirty close of it must keep working.
        local stash, written = load_stash(true)
        local path = stash.for_kind("kumite-stash-").save({ id = "local-1234567", code = "x" })
        assert.are.equal("/tmp/kumite-stash-local-1234567.json", path)
        assert.are.equal(1, #written)
    end)

    it("saves, reads back and deletes an entry with a valid 24-hex id", function()
        for _, prefix in ipairs({ "kumite-stash-", "kata-stash-" }) do
            local kind = load_real_stash().for_kind(prefix)
            local path = kind.save({ id = VALID_ID, code = "answer" })
            assert.are.equal(prefix .. VALID_ID .. ".json", vim.fs.basename(path))
            assert.are.equal(1, vim.fn.filereadable(path))
            assert.are.equal("answer", kind.get(VALID_ID).code)
            assert.is_true(kind.delete(VALID_ID))
            assert.are.equal(0, vim.fn.filereadable(path))
            assert.is_nil(kind.get(VALID_ID))
        end
    end)

    it("keeps the stash inside the cache dir for a valid upper-case id", function()
        local kind = load_real_stash().for_kind("kumite-stash-")
        local path = kind.save({ id = VALID_ID:upper(), code = "x" })
        local cache_dir = require("codewars.cache.utils").cache_file("probe"):parent():absolute()
        assert.are.equal(cache_dir, vim.fs.dirname(path))
        kind.delete(VALID_ID:upper())
    end)
end)
