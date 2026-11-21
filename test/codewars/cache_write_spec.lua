-- A caller that reports a failed cache write itself, once and in its own
-- words, asks write_json not to log one more line per failure.
local P = require("plenary.path")

describe("cache.utils write_json", function()
    local config = require("codewars.config")
    local log = require("codewars.logger")
    local cache_utils = require("codewars.cache.utils")
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
end)
