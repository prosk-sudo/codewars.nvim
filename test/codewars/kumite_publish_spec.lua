local ID = "6a63d4fba3713e60b587d2f3"

-- publish.lua binds `attempt` and `api_utils` at load, so stub them and
-- re-require it fresh for each scenario (also resets its module-local BUSY).
local function load_publish(submit_fn, post_calls)
    package.loaded["codewars.api.attempt"] = { submit = submit_fn }
    package.loaded["codewars.api.utils"] = {
        post = function(endpoint, opts)
            table.insert(post_calls, { endpoint = endpoint, body = opts.body })
            opts.callback(post_calls.response, post_calls.err)
        end,
    }
    package.loaded["codewars.kumite.publish"] = nil
    return require("codewars.kumite.publish")
end

local PASS = { completed = true, passed = 1, failed = 0, errors = 0 }

local function submit_returns(res, err)
    return function(_code, _lang, _fix, _tf, relay, _ver, _opts, cb)
        _G._last_relay = relay
        cb(res, err)
    end
end

local function args()
    return { id = ID, language = "python", code = "x", fixture = "f",
        test_framework = "cw-2", language_version = "3.11", setup = "" }
end

describe("kumite.publish.run_and_publish", function()
    it("runs with relayId = id, then POSTs token + run_result and returns the url", function()
        local posts = { response = { success = true, completed = true, validToken = true } }
        local publish = load_publish(submit_returns({ token = "tok-123", result = PASS }), posts)
        local got
        publish.run_and_publish(args(), function(url, err) got = { url = url, err = err } end)

        assert.are.equal(ID, _G._last_relay)          -- run bound to the snippet
        assert.are.equal("/kumite/" .. ID .. "/publish", posts[1].endpoint)
        assert.are.equal("tok-123", posts[1].body.token)
        assert.is_string(posts[1].body.run_result)     -- serialized result blob
        assert.truthy(posts[1].body.run_result:match("\"result\""))
        assert.is_nil(got.err)
        assert.are.equal("https://www.codewars.com/kumite/" .. ID, got.url)
    end)

    it("refuses to publish when tests do not all pass (no publish POST)", function()
        local posts = {}
        local publish = load_publish(submit_returns({ token = "t", result = { completed = true, failed = 1 } }), posts)
        local got_err
        publish.run_and_publish(args(), function(_, err) got_err = err end)
        assert.are.equal(0, #posts)
        assert.truthy(got_err.msg:match("must pass"))
    end)

    it("refuses to publish when the runner returns no token", function()
        local posts = {}
        local publish = load_publish(submit_returns({ result = PASS }), posts) -- no token
        local got_err
        publish.run_and_publish(args(), function(_, err) got_err = err end)
        assert.are.equal(0, #posts)
        assert.truthy(got_err.msg:match("must pass"))
    end)

    it("reports a rejected token from the publish endpoint", function()
        local posts = { response = { success = false, validToken = false } }
        local publish = load_publish(submit_returns({ token = "t", result = PASS }), posts)
        local got_err
        publish.run_and_publish(args(), function(_, err) got_err = err end)
        assert.truthy(got_err.msg:match("token rejected"))
    end)

    it("passes a runner transport/auth error straight through", function()
        local posts = {}
        local publish = load_publish(submit_returns(nil, { msg = "Session expired", auth = true }), posts)
        local got_err
        publish.run_and_publish(args(), function(_, err) got_err = err end)
        assert.are.equal(0, #posts)
        assert.is_true(got_err.auth)
    end)
end)
