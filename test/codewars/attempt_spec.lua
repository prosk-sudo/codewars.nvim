describe("api.attempt", function()
    -- We test the authorize callback logic by mocking api_utils.post
    local original_post

    -- Stub logger
    package.loaded["codewars.logger"] = package.loaded["codewars.logger"] or {
        info = function() end,
        warn = function() end,
        error = function() end,
        debug = function() end,
    }

    local attempt = require("codewars.api.attempt")
    local api_utils = require("codewars.api.utils")
    local urls = require("codewars.api.urls")

    before_each(function()
        original_post = api_utils.post
    end)

    after_each(function()
        api_utils.post = original_post
    end)

    describe("authorize", function()
        it("extracts token on success", function()
            api_utils.post = function(endpoint, opts)
                opts.callback({ token = "test-token-123" }, nil)
            end

            local received_token, received_err
            attempt.authorize(function(token, err)
                received_token = token
                received_err = err
            end)

            assert.are.equal("test-token-123", received_token)
            assert.is_nil(received_err)
        end)

        it("propagates API error", function()
            api_utils.post = function(endpoint, opts)
                opts.callback(nil, { msg = "Network error" })
            end

            local received_token, received_err
            attempt.authorize(function(token, err)
                received_token = token
                received_err = err
            end)

            assert.is_nil(received_token)
            assert.is_not_nil(received_err)
            assert.truthy(received_err.msg:find("Network"))
        end)

        it("returns specific error when no token in response", function()
            api_utils.post = function(endpoint, opts)
                opts.callback({ other = "data" }, nil)
            end

            local received_token, received_err
            attempt.authorize(function(token, err)
                received_token = token
                received_err = err
            end)

            assert.is_nil(received_token)
            assert.is_not_nil(received_err)
            assert.truthy(received_err.msg:find("authorization token"))
        end)
    end)

    describe("notify", function()
        it("calls post with correct endpoint", function()
            local called_endpoint
            api_utils.post = function(endpoint, opts)
                called_endpoint = endpoint
                if opts.callback then opts.callback() end
            end

            attempt.notify("proj-123", "sol-456", { code = "x" })
            assert.is_not_nil(called_endpoint)
            assert.truthy(called_endpoint:find("proj%-123"))
            assert.truthy(called_endpoint:find("sol%-456"))
        end)
    end)
end)
