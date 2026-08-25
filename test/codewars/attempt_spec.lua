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

    -- attempt.run drives curl through jobstart. curl exits 0 on a 401 or a
    -- 429, so without a status check the runner's JSON error body was
    -- handed to the caller as a test RESULT; and a failed spawn never
    -- fired on_exit, so the runner waited forever.
    describe("run", function()
        local real_jobstart = vim.fn.jobstart
        local script, calls
        local function write(path, s)
            local f = assert(io.open(path, "w")); f:write(s); f:close()
        end
        before_each(function()
            calls = 0
            vim.fn.jobstart = function(cmd, opts)
                calls = calls + 1
                local r = script(cmd)
                if r.spawn_fail then return 0 end
                local hdr
                for i, a in ipairs(cmd) do if a == "-D" then hdr = cmd[i + 1] end end
                write(hdr, r.headers or "HTTP/2 200\r\n\r\n")
                if r.body then opts.on_stdout(nil, { r.body }) end
                opts.on_exit(nil, r.exit or 0)
                return 7
            end
        end)
        after_each(function() vim.fn.jobstart = real_jobstart end)

        local function run()
            local done, got
            attempt.run("tok", "code", "python", "fixture", "cw-2", "sol", nil, nil, function(res, err)
                got = { res, err }; done = true
            end)
            vim.wait(2000, function() return done end)
            assert.is_true(done, "callback never fired")
            return got[1], got[2]
        end

        it("hands a 200 JSON body to the caller as the result", function()
            script = function() return { body = '{"result":{"passed":1}}' } end
            local res, err = run()
            assert.is_nil(err)
            assert.are.equal(1, res.result.passed)
        end)

        it("reports a 429 as rate_limited, never as a result", function()
            script = function() return { headers = "HTTP/2 429\r\nretry-after: 5\r\n\r\n", body = '{"error":"too many requests"}' } end
            local res, err = run()
            assert.is_nil(res)
            assert.is_true(err.rate_limited)
            assert.are.equal(5, err.retry_after)
        end)

        it("reports a 401 as an auth error", function()
            script = function() return { headers = "HTTP/2 401\r\n\r\n", body = '{"error":"unauthorized"}' } end
            local _, err = run()
            assert.is_true(err.auth)
        end)

        it("still surfaces a curl exit code", function()
            script = function() return { exit = 7 } end
            local _, err = run()
            assert.are.equal(7, err.code)
            assert.is_true(err.curl)
        end)

        it("calls back when the job cannot even be started, and leaves no temp file behind", function()
            local seen_tmp
            script = function(cmd)
                for i, a in ipairs(cmd) do if a == "-d" then seen_tmp = cmd[i + 1]:sub(2) end end
                return { spawn_fail = true }
            end
            local _, err = run()
            assert.is_true(err.curl)
            assert.truthy(err.msg:find("curl", 1, true))
            assert.are.equal(0, vim.fn.filereadable(seen_tmp))
        end)

        it("treats a non-object JSON body as a parse failure, not a result", function()
            script = function() return { body = "42" } end
            local res, err = run()
            assert.is_nil(res)
            assert.truthy(err.msg:find("parse", 1, true))
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
