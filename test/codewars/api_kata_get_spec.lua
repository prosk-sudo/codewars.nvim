-- A caller that paces its own requests must opt out of the request layer's 429 retries,
-- which would spend the rate-limit window's slots.
describe("api.kata.get", function()
    local utils = require("codewars.api.utils")
    local kata = require("codewars.api.kata")
    local real_get, sent

    before_each(function()
        real_get = utils.get
        sent = nil
        utils.get = function(endpoint, opts) sent = { endpoint = endpoint, opts = opts } end
    end)

    after_each(function()
        utils.get = real_get
    end)

    it("hands the request options to the request layer beside the callback", function()
        local cb = function() end
        local cancelled = function() return false end
        kata.get("multiply", cb, { retry_rate_limited = false, cancelled = cancelled })
        assert.truthy(sent.endpoint:find("multiply", 1, true), sent.endpoint)
        assert.equals(cb, sent.opts.callback)
        assert.equals(false, sent.opts.retry_rate_limited)
        assert.equals(cancelled, sent.opts.cancelled)
    end)

    it("asks as it always did without options", function()
        local cb = function() end
        kata.get("multiply", cb)
        assert.same({ callback = cb }, sent.opts)
    end)
end)
