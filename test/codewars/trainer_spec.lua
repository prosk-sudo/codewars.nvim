describe("api.trainer", function()
    package.loaded["codewars.logger"] = {
        info = function() end,
        warn = function() end,
        error = function() end,
        err = function() end,
        debug = function() end,
    }

    -- Controllable api.utils stub
    local post_calls = {}
    local post_response = { res = nil, err = nil }
    package.loaded["codewars.api.utils"] = {
        post = function(endpoint, opts)
            table.insert(post_calls, { endpoint = endpoint, body = opts.body, retry = opts.retry })
            opts.callback(post_response.res, post_response.err)
        end,
    }

    package.loaded["codewars.api.trainer"] = nil
    local trainer = require("codewars.api.trainer")

    before_each(function()
        post_calls = {}
        post_response = { res = nil, err = nil }
    end)

    describe("_parse", function()
        it("parses the legacy JSON shape (slug + id)", function()
            local kata = trainer._parse({ success = true, slug = "multiply", id = "abc123" })
            assert.are.equal("multiply", kata.slug)
            assert.are.equal("abc123", kata.id)
        end)

        it("parses an id-only response", function()
            local kata = trainer._parse({ id = "abc123" })
            assert.are.equal("abc123", kata.slug)
        end)

        it("parses an HTML redirect body", function()
            local html = '<a href="/kata/valid-braces/train/python">Train</a>'
            local kata = trainer._parse(html)
            assert.are.equal("valid-braces", kata.slug)
        end)

        it("returns a drift error for an unexpected table", function()
            local kata, err = trainer._parse({ success = true })
            assert.is_nil(kata)
            assert.truthy(err.msg:match("unexpected shape"))
        end)

        it("rejects slugs with path or shell metacharacters as drift", function()
            local kata, err = trainer._parse({ success = true, slug = "../../../etc/passwd" })
            assert.is_nil(kata)
            assert.truthy(err.msg:match("unexpected shape"))
        end)

        it("rejects a success=false envelope instead of mounting its slug", function()
            local kata, err = trainer._parse({ success = false, slug = "stale-kata" })
            assert.is_nil(kata)
            assert.truthy(err.msg:match("refused"))
        end)

        it("classifies a 200 login page as auth failure, not drift", function()
            local kata, err = trainer._parse("<html><body>Sign In to Codewars</body></html>")
            assert.is_nil(kata)
            assert.is_true(err.auth)
            assert.truthy(err.msg:match("cookie"))
        end)

        it("returns a drift error for unexpected HTML", function()
            local kata, err = trainer._parse("<html><body>nothing useful here</body></html>")
            assert.is_nil(kata)
            assert.truthy(err.msg:match("unexpected shape"))
        end)

        it("returns a drift error for vim.NIL", function()
            local kata, err = trainer._parse(vim.NIL)
            assert.is_nil(kata)
            assert.is_not_nil(err)
        end)
    end)

    describe("next_kata", function()
        it("rejects unknown categories without calling the API", function()
            local got_err
            trainer.next_kata("nonsense", "python", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("Unknown focus category"))
            assert.are.equal(0, #post_calls)
        end)

        it("posts the mapped strategy token to the per-language endpoint", function()
            post_response.res = { slug = "multiply" }
            trainer.next_kata("fundamentals", "python", function() end)
            assert.are.equal("/api/v1/code-challenges/python/train", post_calls[1].endpoint)
            assert.are.equal("reference_workout", post_calls[1].body.strategy)
        end)

        it("disables retries (each POST advances the focus queue)", function()
            post_response.res = { slug = "multiply" }
            trainer.next_kata("fundamentals", "python", function() end)
            assert.are.equal(0, post_calls[1].retry)
        end)

        it("maps every category to a distinct token", function()
            local seen = {}
            for cat, token in pairs(trainer.STRATEGIES) do
                assert.is_nil(seen[token], cat .. " duplicates token " .. token)
                seen[token] = cat
            end
            assert.is_not_nil(trainer.STRATEGIES.fundamentals)
            assert.is_not_nil(trainer.STRATEGIES.rank_up)
            assert.is_not_nil(trainer.STRATEGIES.practice_and_repeat)
            assert.is_not_nil(trainer.STRATEGIES.beta)
            assert.is_nil(trainer.STRATEGIES.random) -- client-side by design
        end)

        it("returns the parsed kata on success", function()
            post_response.res = { slug = "multiply", id = "abc" }
            local got
            trainer.next_kata("rank_up", "go", function(kata) got = kata end)
            assert.are.equal("multiply", got.slug)
        end)

        it("maps 404 to a language-support message", function()
            post_response.err = { status = 404, msg = "http error 404" }
            local got_err
            trainer.next_kata("beta", "cobol", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("may not support"))
        end)

        it("passes auth errors through untouched", function()
            post_response.err = { status = 401, auth = true, msg = "Session expired or invalid. Run :CW cookie to re-authenticate." }
            local got_err
            trainer.next_kata("beta", "python", function(_, err) got_err = err end)
            assert.is_true(got_err.auth)
            assert.truthy(got_err.msg:match("cookie"))
        end)

        it("surfaces drift as an explicit error (never silent)", function()
            post_response.res = { totally = "unexpected" }
            local got_err
            trainer.next_kata("rank_up", "python", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("unexpected shape"))
        end)
    end)
end)
