-- :CW unfinished can have more kata the catalogue lacks than the 50 a lookup
-- sends at once (50 keeps a burst well under Codewars' ~60 requests a minute).
-- completed.enrich can carry on past them, paced like the kata-list build and
-- only while its caller still wants the names. Timers and the API are stubbed
-- so that none of this waits or touches the network.
local P = require("plenary.path")

describe("completed.enrich past its first 50", function()
    local config = require("codewars.config")
    local problemlist = require("codewars.cache.problemlist")
    local completed = require("codewars.cache.completed")

    local FIRST_BATCH = 50
    local saved = {}
    local tmp, requests, held, hold, timers, progress, going, script

    local function slug_at(i) return ("kata-%03d"):format(i) end

    local function items(n)
        local list = {}
        for i = 1, n do list[i] = { slug = slug_at(i) } end
        return list
    end

    local function found(slug)
        return { name = "Name of " .. slug, rank = { id = -8, name = "8 kyu" }, tags = { "Fundamentals" } }
    end

    --- Run the oldest timer that was asked for, as if its delay had passed.
    local function run_timer()
        local timer = table.remove(timers, 1)
        timer.fn()
        return timer
    end

    local function drain()
        local guard = 0
        while #timers > 0 and guard < 5000 do
            run_timer()
            guard = guard + 1
        end
    end

    --- The caller :CW unfinished is: asks for names, wants the rest while its
    --- picker is open, and is told whenever more names are saved.
    local function enrich(n, opts)
        local first = 0
        local asked = vim.tbl_extend("force", {
            names = true,
            keep_going = function() return going end,
            on_progress = function() progress[#progress + 1] = vim.tbl_count(completed.get_details()) end,
        }, opts or {})
        completed.enrich(items(n), function() first = first + 1 end, asked)
        return first
    end

    local function details() return completed.get_details() end

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved = {
            storage = config.storage,
            username = config.user.username,
            api = package.loaded["codewars.api.kata"],
            spinner = package.loaded["codewars.logger.spinner"],
            defer_fn = vim.defer_fn,
        }
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        config.user.username = "me"
        completed.clear() -- names a test could not save are kept in memory, across tests too
        requests, held, hold, timers, progress, going = {}, {}, false, {}, {}, true
        script = function(slug) return found(slug) end

        package.loaded["codewars.api.kata"] = {
            get = function(slug, cb, opts)
                requests[#requests + 1] = { slug = slug, opts = opts }
                local res, err = script(slug, #requests)
                if hold then
                    held[#held + 1] = function() cb(res, err) end
                else
                    cb(res, err)
                end
            end,
        }
        local quiet = { update = function() end, success = function() end, error = function() end }
        package.loaded["codewars.logger.spinner"] = { start = function() return quiet end }
        vim.defer_fn = function(fn, ms) timers[#timers + 1] = { fn = fn, ms = ms } end
    end)

    after_each(function()
        vim.defer_fn = saved.defer_fn
        config.storage = saved.storage
        config.user.username = saved.username
        package.loaded["codewars.api.kata"] = saved.api
        package.loaded["codewars.logger.spinner"] = saved.spinner
        vim.fn.delete(tmp, "rf")
    end)

    it("sends the first 50 at once, then the rest one at a time at the pace", function()
        local first = enrich(120)
        assert.equals(1, first, "the first batch was not reported")
        assert.equals(FIRST_BATCH, #requests)
        assert.equals(1, #timers, "the rest was not scheduled")
        assert.is_true(timers[1].ms > problemlist.PACE_MS - 100 and timers[1].ms <= problemlist.PACE_MS, timers[1].ms)

        hold = true
        for n = FIRST_BATCH + 1, 120 do
            run_timer()
            assert.equals(n, #requests)
            assert.equals(slug_at(n), requests[n].slug)
            assert.equals(false, requests[n].opts.retry_rate_limited, "the request layer would retry a refusal itself")
            assert.equals(0, #timers, "asked for the next before this one was answered")
            table.remove(held, 1)()
            if n < 120 then
                assert.equals(1, #timers)
                assert.is_true(timers[1].ms > problemlist.PACE_MS - 100 and timers[1].ms <= problemlist.PACE_MS,
                    timers[1].ms)
            end
        end
    end)

    it("caches every name, and tells the open picker as they arrive", function()
        enrich(120)
        drain()
        for i = 1, 120 do
            assert.equals("Name of " .. slug_at(i), details()[slug_at(i)].name, slug_at(i))
        end
        assert.is_true(#progress >= 2, vim.inspect(progress))
        assert.is_true(progress[1] > FIRST_BATCH, "the first update came with nothing new")
        for i = 2, #progress do assert.is_true(progress[i] > progress[i - 1], vim.inspect(progress)) end
        assert.equals(120, progress[#progress])
    end)

    -- :CW completed asks as it always did, and stops at 50.
    it("does not look past the first 50 for a caller that did not ask", function()
        completed.enrich(items(120), function() end)
        assert.equals(FIRST_BATCH, #requests)
        assert.equals(0, #timers)
    end)

    it("nor for one that wants names but gave no way to tell it when to stop", function()
        completed.enrich(items(120), function() end, { names = true })
        assert.equals(FIRST_BATCH, #requests)
        assert.equals(0, #timers)
    end)

    it("schedules nothing when the first 50 are all there is", function()
        enrich(FIRST_BATCH)
        assert.equals(FIRST_BATCH, #requests)
        assert.equals(0, #timers)
    end)

    it("stops, keeping what it has, once its caller no longer wants the names", function()
        enrich(120)
        for _ = 1, 8 do run_timer() end
        assert.equals(FIRST_BATCH + 8, #requests)
        going = false
        drain()
        assert.equals(FIRST_BATCH + 8, #requests, "sent a request after the picker closed")
        assert.equals(FIRST_BATCH + 8, vim.tbl_count(details()))
        assert.equals("Name of " .. slug_at(FIRST_BATCH + 8), details()[slug_at(FIRST_BATCH + 8)].name)
    end)

    it("stops and saves nothing more when the account changes", function()
        enrich(120)
        for _ = 1, 7 do run_timer() end
        local saved_so_far = vim.tbl_count(details())
        config.user.username = "someone-else"
        drain()
        assert.equals(FIRST_BATCH + 7, #requests, "sent a request for an account that was gone")
        assert.equals(saved_so_far, vim.tbl_count(details()), "saved after the account changed")
    end)

    it("stops and leaves the cache cleared when it is cleared during the run", function()
        enrich(120)
        for _ = 1, 7 do run_timer() end
        completed.clear()
        drain()
        assert.equals(FIRST_BATCH + 7, #requests, "sent a request after the cache was cleared")
        assert.same({}, details())
    end)

    describe("when Codewars refuses a request", function()
        local TARGET = FIRST_BATCH + 2

        it("waits the cooldown out, doubling it, and asks for the same kata again", function()
            local refusals = 2
            script = function(slug)
                if slug == slug_at(TARGET) and refusals > 0 then
                    refusals = refusals - 1
                    return nil, { rate_limited = true, msg = "429" }
                end
                return found(slug)
            end
            enrich(120)
            run_timer()
            run_timer()
            assert.equals(TARGET, #requests)
            assert.equals(1, #timers)
            assert.equals(problemlist.COOLDOWN_MS, timers[1].ms)

            repeat run_timer() until #requests > TARGET or #timers == 0
            assert.equals(slug_at(TARGET), requests[TARGET + 1].slug, "went on to another kata")
            assert.equals(1, #timers)
            assert.equals(problemlist.COOLDOWN_MS * 2, timers[1].ms)

            drain()
            assert.equals(slug_at(TARGET), requests[TARGET + 2].slug)
            assert.equals("Name of " .. slug_at(TARGET), details()[slug_at(TARGET)].name)
            assert.equals("Name of " .. slug_at(120), details()[slug_at(120)].name)
        end)

        it("gives up after as many refusals in a row as the kata list build allows, keeping what it has", function()
            script = function(slug)
                if slug == slug_at(TARGET) then return nil, { rate_limited = true, msg = "429" } end
                return found(slug)
            end
            enrich(120)
            drain()
            local asked_for_it = vim.tbl_filter(function(r) return r.slug == slug_at(TARGET) end, requests)
            assert.equals(problemlist.MAX_COOLDOWNS + 1, #asked_for_it)
            assert.equals(TARGET - 1 + problemlist.MAX_COOLDOWNS + 1, #requests, "went on after giving up")
            assert.equals("Name of " .. slug_at(TARGET - 1), details()[slug_at(TARGET - 1)].name)
        end)
    end)

    it("counts any other failure against that kata alone and moves on", function()
        script = function(slug)
            if slug == slug_at(FIRST_BATCH + 2) then return nil, { msg = "HTTP 500", status = 500 } end
            return found(slug)
        end
        enrich(120)
        drain()
        local tries = vim.tbl_filter(function(r) return r.slug == slug_at(FIRST_BATCH + 2) end, requests)
        assert.equals(1, #tries, "expected one request for it, and no retry")
        assert.is_nil(details()[slug_at(FIRST_BATCH + 2)])
        assert.equals("Name of " .. slug_at(120), details()[slug_at(120)].name)
        assert.equals(119, vim.tbl_count(details()))
    end)

    -- A cache directory that is read-only or full: the names are looked up
    -- all the same, the user is told once, and the open picker still gets
    -- them -- from memory, until a write lands.
    describe("when the details cannot be saved", function()
        local cache_utils = require("codewars.cache.utils")
        local log = require("codewars.logger")
        local real_write, real_warn, warns, writes_work

        before_each(function()
            real_write, real_warn = cache_utils.write_json, log.warn
            warns, writes_work = {}, false
            log.warn = function(msg) warns[#warns + 1] = tostring(msg) end
            cache_utils.write_json = function(path, data, opts)
                if writes_work then return real_write(path, data, opts) end
                return false, "disk full"
            end
        end)

        after_each(function()
            cache_utils.write_json, log.warn = real_write, real_warn
        end)

        it("tells the user once for the whole run, and carries on", function()
            enrich(120)
            drain()
            assert.equals(1, #warns, vim.inspect(warns))
            assert.truthy(warns[1]:find("disk full", 1, true), warns[1])
            assert.equals(120, #requests)
        end)

        it("still gives the picker every name, as they arrive", function()
            enrich(120)
            drain()
            for i = 1, 120 do
                assert.equals("Name of " .. slug_at(i), details()[slug_at(i)].name, slug_at(i))
            end
            assert.is_true(#progress >= 2, vim.inspect(progress))
            for i = 2, #progress do assert.is_true(progress[i] > progress[i - 1], vim.inspect(progress)) end
            assert.equals(120, progress[#progress])
        end)

        it("writes what it has once the disk takes writes again", function()
            enrich(120)
            for _ = 1, 8 do run_timer() end
            writes_work = true
            drain()
            writes_work = false -- so that only what reached the disk is read below
            local on_disk = cache_utils.read_json(require("codewars.cache.utils").cache_file("kata_details.json"))
            assert.equals(120, vim.tbl_count(on_disk), "names found while it could not write were lost")
        end)

        it("forgets what it could not save when the cache is cleared", function()
            enrich(120)
            for _ = 1, 8 do run_timer() end
            completed.clear()
            assert.same({}, details())
        end)
    end)

    -- The first batch holds what the cache held when it began, for the whole
    -- time its requests are out. What it saves has to be what it fetched,
    -- added to the cache as it is at that moment.
    describe("the first batch, while the cache changes under it", function()
        local calls

        local function deliver_all()
            while #held > 0 do table.remove(held, 1)() end
        end

        --- Deliver the oldest `n` replies still held; each can bring on more requests.
        local function deliver(n)
            for _ = 1, n do table.remove(held, 1)() end
        end

        local function start_big_run()
            calls = {}
            hold = true
            completed.enrich(items(120), function(enriched, err)
                calls[#calls + 1] = { items = enriched, err = err }
            end, {
                names = true,
                keep_going = function() return going end,
                on_progress = function() end,
            })
        end

        it("keeps what another lookup saved meanwhile, whichever of the two finishes last", function()
            for _, order in ipairs({ "b first", "a first" }) do
                completed.clear()
                requests, held, hold = {}, {}, true
                completed.enrich({ { slug = "a1" }, { slug = "a2" } }, function() end)
                completed.enrich({ { slug = "b1" }, { slug = "b2" } }, function() end)
                assert.equals(4, #held)
                local a, b = { held[1], held[2] }, { held[3], held[4] }
                local first, second = order == "b first" and b or a, order == "b first" and a or b
                first[1](); first[2]()
                second[1](); second[2]()
                for _, slug in ipairs({ "a1", "a2", "b1", "b2" }) do
                    assert.is_not_nil(details()[slug], ("%s lost when %s: %s"):format(slug, order, vim.inspect(details())))
                end
            end
        end)

        it("saves nothing, asks for nothing more and starts no continuation when the account changes", function()
            start_big_run()
            deliver(10)
            config.user.username = "someone-else"
            local asked = #requests
            deliver_all()
            assert.equals(asked, #requests, "asked for more after the account changed")
            assert.same({}, details(), "saved for an account that was gone")
            assert.equals(0, #timers, "started the rest under the new account")
            assert.equals(1, #calls, "the caller was not answered exactly once")
            assert.truthy(calls[1].err and calls[1].err.msg:find("account", 1, true), vim.inspect(calls[1].err))
        end)

        it("leaves the cache cleared, and starts nothing, when it is cleared", function()
            start_big_run()
            deliver(10)
            completed.clear()
            local asked = #requests
            deliver_all()
            assert.equals(asked, #requests, "asked for more after the cache was cleared")
            assert.same({}, details(), "brought the cleared cache back")
            assert.equals(0, #timers)
            assert.equals(1, #calls)
            assert.is_not_nil(calls[1].err)
        end)

        it("answers with no error, and goes on to the rest, when nothing changed", function()
            start_big_run()
            deliver_all()
            assert.equals(1, #calls)
            assert.is_nil(calls[1].err)
            assert.equals(FIRST_BATCH, vim.tbl_count(details()))
            assert.equals(1, #timers, "the rest was not started")
        end)
    end)
end)
