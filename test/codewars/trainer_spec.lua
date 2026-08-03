describe("api.trainer", function()
    package.loaded["codewars.logger"] = {
        info = function() end,
        warn = function() end,
        error = function() end,
        err = function() end,
        debug = function() end,
    }

    -- Controllable api.utils stub. Responses are consumed FIFO so multi-call
    -- flows (skip = pop + peek) can be scripted per test; `hold` parks
    -- callbacks to exercise the in-flight mutex.
    local get_calls = {}
    local get_responses = {}
    local hold = false
    local held = {}
    package.loaded["codewars.api.utils"] = {
        get = function(endpoint, opts)
            table.insert(get_calls, { endpoint = endpoint, retry = opts.retry })
            if hold then
                table.insert(held, opts.callback)
                return
            end
            local r = table.remove(get_responses, 1) or {}
            opts.callback(r.res, r.err)
        end,
    }

    package.loaded["codewars.api.trainer"] = nil
    local trainer = require("codewars.api.trainer")

    local HEX = ("a"):rep(24)

    -- Completed-kata set driving the self-heal, swapped in per test.
    local completed = {}
    trainer._is_completed = function(kata)
        return kata ~= nil and completed[kata.slug] == true
    end

    before_each(function()
        get_calls = {}
        get_responses = {}
        hold = false
        held = {}
        completed = {}
    end)

    describe("_parse", function()
        it("parses the legacy JSON shape (slug + id)", function()
            local kata = trainer._parse({ success = true, slug = "multiply", id = "abc123" })
            assert.are.equal("multiply", kata.slug)
            assert.are.equal("abc123", kata.id)
        end)

        it("parses an id-only response (peek endpoint shape)", function()
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
            assert.are.equal(0, #get_calls)
        end)

        it("peeks the mapped strategy token with dequeue=false", function()
            get_responses = { { res = { success = true, id = HEX } } }
            trainer.next_kata("fundamentals", "python", function() end)
            assert.are.equal("/trainer/peek/python/reference_workout?dequeue=false", get_calls[1].endpoint)
        end)

        it("keeps the shared retry default (peek is idempotent)", function()
            get_responses = { { res = { success = true, id = HEX } } }
            trainer.next_kata("fundamentals", "python", function() end)
            assert.is_nil(get_calls[1].retry)
        end)

        it("rejects a second fetch while one is in flight", function()
            hold = true
            trainer.next_kata("fundamentals", "python", function() end)
            local got_err
            trainer.next_kata("rank_up", "python", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("Already fetching"))
            assert.are.equal(1, #get_calls)

            held[1]({ success = true, id = HEX })
            hold = false
            get_responses = { { res = { success = true, id = HEX } } }
            trainer.next_kata("rank_up", "python", function() end)
            assert.are.equal(2, #get_calls)
        end)

        it("maps every category to a distinct token", function()
            local seen = {}
            for cat, token in pairs(trainer.STRATEGIES) do
                assert.is_nil(seen[token], cat .. " duplicates token " .. token)
                seen[token] = cat
            end
            assert.are.equal("reference_workout", trainer.STRATEGIES.fundamentals)
            assert.are.equal("default", trainer.STRATEGIES.rank_up)
            assert.are.equal("retrain_workout", trainer.STRATEGIES.practice_and_repeat)
            assert.are.equal("beta_workout", trainer.STRATEGIES.beta)
            assert.is_nil(trainer.STRATEGIES.random) -- client-side by design
        end)

        it("returns the parsed kata (peek returns id only, like the live capture)", function()
            get_responses = { { res = {
                success = true, strategy = "default", language = "java",
                id = "5277c8a221e209d3f6000b56", name = "Valid Braces", rank = -6,
                href = "/kata/5277c8a221e209d3f6000b56",
            } } }
            local got
            trainer.next_kata("rank_up", "java", function(kata) got = kata end)
            assert.are.equal("5277c8a221e209d3f6000b56", got.slug)
        end)

        it("maps 404 to a language-support message", function()
            get_responses = { { err = { status = 404, msg = "http error 404" } } }
            local got_err
            trainer.next_kata("beta", "cobol", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("may not support"))
        end)

        it("passes auth errors through untouched", function()
            get_responses = { { err = { status = 401, auth = true, msg = "Session expired or invalid. Run :CW cookie to re-authenticate." } } }
            local got_err
            trainer.next_kata("beta", "python", function(_, err) got_err = err end)
            assert.is_true(got_err.auth)
            assert.truthy(got_err.msg:match("cookie"))
        end)

        it("surfaces drift as an explicit error (never silent)", function()
            get_responses = { { res = { totally = "unexpected" } } }
            local got_err
            trainer.next_kata("rank_up", "python", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("unexpected shape"))
        end)
    end)

    describe("completed self-heal", function()
        it("pops a solved kata off the head and serves the next one", function()
            completed["solved-one"] = true
            get_responses = {
                { res = { success = true, slug = "solved-one" } },  -- stale head
                { res = { success = true, slug = "solved-one" } },  -- the pop
                { res = { success = true, slug = "fresh-one" } },   -- new head
            }
            local got
            trainer.next_kata("fundamentals", "python", function(kata) got = kata end)
            assert.are.equal("fresh-one", got.slug)
            assert.are.equal("/trainer/peek/python/reference_workout?dequeue=true", get_calls[2].endpoint)
        end)

        it("leaves practice_and_repeat alone (it serves solved kata by design)", function()
            completed["solved-one"] = true
            get_responses = { { res = { success = true, slug = "solved-one" } } }
            local got
            trainer.next_kata("practice_and_repeat", "python", function(kata) got = kata end)
            assert.are.equal("solved-one", got.slug)
            assert.are.equal(1, #get_calls) -- never popped
        end)

        it("gives up after 3 advances instead of looping forever", function()
            completed["solved-one"] = true
            for _ = 1, 12 do
                table.insert(get_responses, { res = { success = true, slug = "solved-one" } })
            end
            local got
            trainer.next_kata("rank_up", "python", function(kata) got = kata end)
            assert.are.equal("solved-one", got.slug) -- returns it rather than spinning
            assert.are.equal(7, #get_calls)          -- peek + 3x(pop, peek)
        end)

        it("does not pop an unsolved head", function()
            get_responses = { { res = { success = true, slug = "fresh-one" } } }
            trainer.next_kata("fundamentals", "python", function() end)
            assert.are.equal(1, #get_calls)
        end)

        it("surfaces a pop failure during self-heal", function()
            completed["solved-one"] = true
            get_responses = {
                { res = { success = true, slug = "solved-one" } },
                { err = { status = 500, msg = "http error 500" } },
            }
            local got_err
            trainer.next_kata("beta", "python", function(_, err) got_err = err end)
            assert.is_not_nil(got_err)
        end)

        it("releases the in-flight lock after a self-heal", function()
            completed["solved-one"] = true
            get_responses = {
                { res = { success = true, slug = "solved-one" } },
                { res = { success = true, slug = "solved-one" } },
                { res = { success = true, slug = "fresh-one" } },
                { res = { success = true, slug = "later-one" } },
            }
            trainer.next_kata("fundamentals", "python", function() end)
            local got
            trainer.next_kata("fundamentals", "python", function(kata) got = kata end)
            assert.are.equal("later-one", got.slug)
        end)
    end)

    describe("advance", function()
        it("pops the queue once, with no retries and no follow-up peek", function()
            get_responses = { { res = { success = true, slug = "popped" } } }
            local got_err = "unset"
            trainer.advance("fundamentals", "python", function(err) got_err = err end)
            assert.are.equal(1, #get_calls)
            assert.are.equal("/trainer/peek/python/reference_workout?dequeue=true", get_calls[1].endpoint)
            assert.are.equal(0, get_calls[1].retry)
            assert.is_nil(got_err)
        end)

        it("reports errors to the caller and frees the lock", function()
            get_responses = {
                { err = { status = 401, auth = true, msg = "Session expired" } },
                { res = { success = true, slug = "fresh-one" } },
            }
            local got_err
            trainer.advance("rank_up", "python", function(err) got_err = err end)
            assert.is_true(got_err.auth)

            local got
            trainer.next_kata("rank_up", "python", function(kata) got = kata end)
            assert.are.equal("fresh-one", got.slug)
        end)

        it("rejects unknown categories without calling the API", function()
            local got_err
            trainer.advance("random", "python", function(err) got_err = err end)
            assert.truthy(got_err.msg:match("Unknown focus category"))
            assert.are.equal(0, #get_calls)
        end)

        it("works without a callback", function()
            get_responses = { { res = { success = true, slug = "popped" } } }
            assert.has_no.errors(function() trainer.advance("beta", "python") end)
        end)
    end)

    describe("skip", function()
        it("pops with dequeue=true (no retries), then peeks the new head", function()
            get_responses = {
                { res = { success = true, id = ("b"):rep(24) } }, -- popped (old head)
                { res = { success = true, id = ("c"):rep(24) } }, -- new head
            }
            local got
            trainer.skip("rank_up", "java", function(kata) got = kata end)
            assert.are.equal("/trainer/peek/java/default?dequeue=true", get_calls[1].endpoint)
            assert.are.equal(0, get_calls[1].retry)
            assert.are.equal("/trainer/peek/java/default?dequeue=false", get_calls[2].endpoint)
            assert.are.equal(("c"):rep(24), got.slug)
        end)

        it("aborts on a pop error without a second request", function()
            get_responses = { { err = { status = 500, msg = "http error 500" } } }
            local got_err
            trainer.skip("beta", "python", function(_, err) got_err = err end)
            assert.is_not_nil(got_err)
            assert.are.equal(1, #get_calls)
        end)

        it("aborts on pop drift without a second request", function()
            get_responses = { { res = { totally = "unexpected" } } }
            local got_err
            trainer.skip("beta", "python", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("unexpected shape"))
            assert.are.equal(1, #get_calls)
        end)

        it("rejects unknown categories without calling the API", function()
            local got_err
            trainer.skip("hardcore", "python", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("Unknown focus category"))
            assert.are.equal(0, #get_calls)
        end)

        it("holds the in-flight lock across both requests", function()
            hold = true
            trainer.skip("rank_up", "python", function() end)

            local got_err
            trainer.next_kata("rank_up", "python", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("Already fetching"))

            -- Release the pop; the follow-up peek is issued and parked too.
            held[1]({ success = true, id = HEX })
            got_err = nil
            trainer.next_kata("rank_up", "python", function(_, err) got_err = err end)
            assert.truthy(got_err.msg:match("Already fetching"))

            -- Release the peek; the lock frees.
            held[2]({ success = true, id = HEX })
            hold = false
            get_responses = { { res = { success = true, id = HEX } } }
            local got
            trainer.next_kata("rank_up", "python", function(kata) got = kata end)
            assert.are.equal(HEX, got.slug)
        end)
    end)
end)
