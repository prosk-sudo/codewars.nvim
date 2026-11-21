-- The partial-cache guard is the crux of the rate-limit work: a truncated
-- list stamped with the current time looks fresh for the whole cache
-- interval and hides every kata the aborted run never fetched. Nothing
-- exercised problemlist.update before this file.
describe("cache.problemlist update", function()
    local warned = {} -- logger.warn messages
    local spinner_errors = {} -- what the build's spinner ended on
    package.loaded["codewars.logger"] = {
        info = function() end, warn = function(msg) warned[#warned + 1] = tostring(msg) end,
        error = function() end, err = function() end, debug = function() end,
    }
    package.loaded["codewars.logger.spinner"] = {
        start = function()
            return {
                update = function() end,
                success = function() end,
                error = function(_, msg) spinner_errors[#spinner_errors + 1] = tostring(msg) end,
            }
        end,
    }
    package.loaded["codewars.config"] = { user = { cache = {} }, lang = "python" }

    local writes = {}
    -- What read_json hands back per file name; the build reads its
    -- checkpoint through this.
    local stored = {}
    package.loaded["codewars.cache.utils"] = {
        cache_file = function(name) return "/tmp/cw-test-" .. tostring(name) end,
        read_json = function(path) return stored[path] end,
        write_json = function(path, data)
            table.insert(writes, { path = path, data = vim.deepcopy(data) })
            return true
        end,
    }

    local LIST = "/tmp/cw-test-problemlist.json"
    local CHECKPOINT = "/tmp/cw-test-problemlist.partial.json"

    local function writes_to(path)
        return vim.tbl_filter(function(w) return w.path == path end, writes)
    end

    -- One scripted response per page request, consumed in order.
    local page_calls = 0
    local page_script = nil
    local requested = {} -- { rank, page, opts } per call
    package.loaded["codewars.api.search"] = {
        fetch_page = function(opts, page, cb)
            page_calls = page_calls + 1
            requested[#requested + 1] = { rank = opts.rank[1], page = page, opts = opts }
            return cb(page_script(page_calls))
        end,
    }

    package.loaded["codewars.cache.problemlist"] = nil
    local problemlist = require("codewars.cache.problemlist")
    -- The real pace and cooldowns are seconds long; the logic is the same.
    problemlist.PACE_MS = 0
    problemlist.COOLDOWN_MS = 1
    problemlist.MAX_COOLDOWN_MS = 4
    problemlist.MAX_COOLDOWNS = 2

    local function run()
        local done, items, partial = false, nil, nil
        problemlist.update({ max_pages = 2 }, function(i, p)
            items, partial, done = i, p, true
        end)
        vim.wait(8000, function() return done end)
        assert.is_true(done, "update never called back")
        return items, partial
    end

    -- Odd calls carry one kata, even calls are the empty page that ends
    -- the rank: every rank is two requests and yields one kata.
    local function one_per_rank(n)
        if n % 2 == 1 then
            return { { slug = "kata-" .. n } }, true, nil
        end
        return {}, false, nil
    end

    before_each(function()
        writes = {}
        stored = {}
        page_calls = 0
        requested = {}
        warned = {}
        spinner_errors = {}
        os.remove(CHECKPOINT)
    end)

    it("writes the cache and reports success on a clean run", function()
        page_script = function(n)
            if n % 2 == 1 then
                return { { slug = "kata-" .. n } }, false, nil
            end
            return {}, false, nil
        end
        local items, partial = run()
        assert.is_nil(partial)
        assert.are.equal(1, #writes_to(LIST))
        assert.is_true(#items > 0)
        assert.is_not_nil(writes_to(LIST)[1].data.timestamp)
    end)

    -- Refusing the write is the whole point: the next run must retry rather
    -- than trust a short list.
    it("does NOT write the cache when rate limiting outlasts every cooldown", function()
        page_script = function(n)
            if n == 1 then return { { slug = "kata-1" } }, true, nil end
            return {}, false, { status = 429, rate_limited = true, msg = "limited" }
        end
        local items, partial = run()
        assert.are.equal(0, #writes_to(LIST), "a partial cache was written")
        assert.is_true(partial)
        assert.is_not_nil(items) -- caller still receives what was collected
    end)

    it("does NOT write the cache when auth aborts the run", function()
        page_script = function(n)
            if n == 1 then return { { slug = "kata-1" } }, true, nil end
            return {}, false, { auth = true, msg = "session expired" }
        end
        local _, partial = run()
        assert.are.equal(0, #writes_to(LIST), "a partial cache was written")
        assert.is_true(partial)
    end)

    -- A 5xx or a dead connection used to fall through both abort checks and
    -- count as an EMPTY page: the rank ended early and the truncated list
    -- was written as fresh — the same hole the 429 path exists to close.
    it("does NOT write the cache when any other fetch error aborts the run", function()
        page_script = function(n)
            if n == 1 then return { { slug = "kata-1" } }, true, nil end
            return {}, false, { status = 502, msg = "http error 502" }
        end
        local items, partial = run()
        assert.are.equal(0, #writes_to(LIST), "a partial cache was written")
        assert.is_true(partial)
        assert.are.equal(1, #items)
    end)

    it("tells fetch_page to stop retrying once the run is aborted", function()
        page_script = function(n)
            if n == 1 then return { { slug = "kata-1" } }, true, nil end
            return {}, false, { status = 429, rate_limited = true, msg = "limited" }
        end
        run()
        local cancelled = requested[1].opts.cancelled
        assert.is_function(cancelled)
        assert.is_true(cancelled())
    end)

    -- The regression behind this file's second half: Codewars answers 429
    -- ~60 requests into any minute, so a build that gave up on the first
    -- one never finished, never cached, and restarted on every :CW list.
    it("waits out a 429 and asks for the SAME page again", function()
        page_script = function(n)
            if n == 2 or n == 3 then
                return {}, false, { status = 429, rate_limited = true, msg = "limited" }
            end
            return one_per_rank(n)
        end
        local items, partial = run()
        assert.is_nil(partial)
        assert.are.equal(1, #writes_to(LIST))
        -- Calls 2 and 3 were refused; call 4 is the retry of that page.
        assert.are.equal(requested[2].page, requested[3].page)
        assert.are.equal(requested[2].page, requested[4].page)
        assert.are.equal(requested[2].rank, requested[4].rank)
        assert.is_true(#items > 0)
    end)

    it("leaves 429 retries to the build, not the request layer", function()
        page_script = one_per_rank
        run()
        assert.is_false(requested[1].opts.retry_rate_limited)
    end)

    it("checkpoints each finished rank and removes the checkpoint at the end", function()
        local f = io.open(CHECKPOINT, "w"); f:write("{}"); f:close()
        page_script = one_per_rank
        run()
        local cps = writes_to(CHECKPOINT)
        assert.are.equal(8, #cps)
        assert.is_not_nil(cps[1].data.ranks["-8"])
        assert.is_nil(io.open(CHECKPOINT, "r"), "checkpoint left behind after a complete build")
    end)

    it("resumes from the checkpoint instead of refetching finished ranks", function()
        stored[CHECKPOINT] = {
            timestamp = os.time() - 60,
            ranks = { ["-8"] = { { slug = "eight" } }, ["-7"] = { { slug = "seven" } } },
        }
        page_script = one_per_rank
        local items, partial = run()
        assert.is_nil(partial)
        for _, r in ipairs(requested) do
            assert.is_true(r.rank ~= -8 and r.rank ~= -7, "refetched a checkpointed rank")
        end
        assert.are.equal(-6, requested[1].rank)
        assert.are.equal("eight", items[1].slug) -- rank order kept
        assert.are.equal("seven", items[2].slug)
        -- Only as fresh as the oldest rank in it.
        assert.are.equal(stored[CHECKPOINT].timestamp, writes_to(LIST)[1].data.timestamp)
    end)

    it("ignores a checkpoint older than the update interval", function()
        stored[CHECKPOINT] = {
            timestamp = os.time() - 31 * 24 * 60 * 60,
            ranks = { ["-8"] = { { slug = "ancient" } } },
        }
        page_script = one_per_rank
        local items = run()
        assert.are.equal(-8, requested[1].rank)
        for _, it_ in ipairs(items) do assert.are_not.equal("ancient", it_.slug) end
    end)

    it("keeps finished ranks across an abort, and never checkpoints an empty rank", function()
        page_script = function(n)
            if n == 1 then return { { slug = "a" } }, true, nil end
            if n == 2 then return {}, false, nil end -- 8 kyu done
            if n == 3 then return {}, false, nil end -- 7 kyu empty
            return {}, false, { status = 502, msg = "http error 502" }
        end
        local _, partial = run()
        assert.is_true(partial)
        local cps = writes_to(CHECKPOINT)
        assert.are.equal(1, #cps)
        assert.same({ { slug = "a" } }, cps[1].data.ranks["-8"])
        assert.is_nil(cps[1].data.ranks["-7"])
    end)

    it("joins a running build instead of starting a second one", function()
        page_script = one_per_rank
        local got = {}
        assert.is_true(problemlist.update({ max_pages = 2 }, function(i) got[#got + 1] = i end))
        assert.is_not_nil(problemlist.building())
        assert.is_false(problemlist.update({}, function(i) got[#got + 1] = i end))
        vim.wait(8000, function() return #got == 2 end)
        assert.are.equal(2, #got)
        assert.are.equal(16, page_calls) -- one build: 8 ranks x 2 pages
        assert.are_not.equal(got[1], got[2]) -- each caller owns its list
        assert.same(got[1], got[2])
        assert.is_nil(problemlist.building())
    end)

    it("deduplicates by slug before writing", function()
        page_script = function(n)
            if n % 2 == 1 then
                return { { slug = "same" }, { slug = "same" } }, false, nil
            end
            return {}, false, nil
        end
        local items = run()
        assert.are.equal(1, #items)
    end)

    -- A page that has result blocks but parses to none is the markup
    -- moving, not a rank running out. It used to read as the end of the rank
    -- and the short list was cached as complete.
    describe("when the search markup drifts", function()
        local DRIFT = { drift = true, msg = "30 results, none readable" }

        it("aborts without writing the cache, and says the markup may have changed", function()
            page_script = function(n)
                if n == 1 then return { { slug = "kata-1" } }, true, nil end
                return {}, false, DRIFT
            end
            local items, partial = run()
            assert.is_true(partial)
            assert.are.equal(0, #writes_to(LIST), "a partial cache was written")
            assert.are.equal(1, #items) -- what was collected still goes to the caller
            assert.are.equal(1, #spinner_errors)
            assert.truthy(spinner_errors[1]:find("markup may have changed", 1, true), spinner_errors[1])
        end)

        it("does not carry on to the next rank", function()
            page_script = function() return {}, false, DRIFT end
            run()
            assert.are.equal(1, page_calls)
        end)

        it("never checkpoints the rank it drifted in", function()
            page_script = function(n)
                if n == 1 then return { { slug = "kata-1" } }, true, nil end
                return {}, false, DRIFT
            end
            run()
            assert.are.equal(0, #writes_to(CHECKPOINT))
        end)

        it("does not retry the page the way it does a rate limit", function()
            page_script = function() return {}, false, DRIFT end
            run()
            assert.are.equal(1, #requested)
        end)
    end)

    -- Blocks that fail to parse on an otherwise readable page are dropped.
    -- That is told once at the end of the build, not once per page.
    describe("when some result blocks cannot be read", function()
        --- Every rank is two pages: one kata, then the empty page that ends it.
        --- `dropped_on` names which calls report dropped blocks, and how many.
        local function with_dropped(dropped_on)
            return function(n)
                if n % 2 == 1 then
                    return { { slug = "kata-" .. n } }, true, nil, dropped_on[n]
                end
                return {}, false, nil
            end
        end

        it("keeps the kata that were read", function()
            page_script = with_dropped({ [1] = 2 })
            local items, partial = run()
            assert.is_nil(partial)
            assert.are.equal(1, #writes_to(LIST))
            assert.are.equal(8, #items)
        end)

        it("warns once, with the total, however many pages dropped some", function()
            page_script = with_dropped({ [1] = 2, [3] = 1, [9] = 4 })
            run()
            assert.are.equal(1, #warned, vim.inspect(warned))
            assert.truthy(warned[1]:find("7", 1, true), warned[1])
            assert.truthy(warned[1]:find("markup may have changed", 1, true), warned[1])
        end)

        it("stays quiet when nothing was dropped", function()
            page_script = with_dropped({})
            run()
            assert.are.same({}, warned)
        end)

        it("still tells how many were dropped when the build stops early", function()
            page_script = function(n)
                if n == 1 then return { { slug = "kata-1" } }, true, nil, 3 end
                return {}, false, { status = 502, msg = "http error 502" }
            end
            local _, partial = run()
            assert.is_true(partial)
            assert.are.equal(1, #warned, vim.inspect(warned))
            assert.truthy(warned[1]:find("3", 1, true), warned[1])
        end)
    end)

    -- A rank finished by a cut-short run is not fetched again, so what its
    -- pages dropped has to travel in the checkpoint, or the build that
    -- completes the list reports success without saying it is missing them.
    describe("when a build is resumed from a checkpoint", function()
        --- Every rank is two pages: one kata, then the empty page that ends it.
        --- `dropped_on` names which calls report dropped blocks, and how many.
        local function with_dropped(dropped_on)
            return function(n)
                if n % 2 == 1 then
                    return { { slug = "kata-" .. n } }, true, nil, dropped_on[n]
                end
                return {}, false, nil
            end
        end

        --- What the most recent checkpoint write left on disk.
        local function last_checkpoint()
            local cps = writes_to(CHECKPOINT)
            return vim.deepcopy(cps[#cps].data)
        end

        it("keeps each finished rank's dropped count in the checkpoint", function()
            page_script = function(n)
                if n == 1 then return { { slug = "a" } }, true, nil, 2 end
                if n == 2 then return {}, false, nil end -- 8 kyu done
                if n == 3 then return { { slug = "b" } }, true, nil, 0 end
                if n == 4 then return {}, false, nil end -- 7 kyu done
                return {}, false, { status = 502, msg = "http error 502" }
            end
            run()
            local cp = last_checkpoint()
            assert.are.equal(2, cp.dropped["-8"])
            assert.is_true((cp.dropped["-7"] or 0) == 0)
        end)

        it("counts what a checkpointed rank dropped in the warning of the build that finishes", function()
            -- Run one: 8 kyu drops 2 and is checkpointed; 7 kyu then fails.
            page_script = function(n)
                if n == 1 then return { { slug = "a" } }, true, nil, 2 end
                if n == 2 then return {}, false, nil end
                return {}, false, { status = 502, msg = "http error 502" }
            end
            local _, partial = run()
            assert.is_true(partial)
            stored[CHECKPOINT] = last_checkpoint()
            warned, page_calls, requested = {}, 0, {}

            -- Run two resumes at 7 kyu, which drops 1.
            page_script = with_dropped({ [1] = 1 })
            local items, resumed_partial = run()
            assert.is_nil(resumed_partial)
            assert.are.equal(-7, requested[1].rank, "refetched the checkpointed rank")
            assert.are.equal(1, #writes_to(LIST))
            assert.is_true(#items > 0)
            assert.are.equal(1, #warned, vim.inspect(warned))
            assert.truthy(warned[1]:find("3", 1, true), warned[1])
            assert.truthy(warned[1]:find("markup may have changed", 1, true), warned[1])
        end)

        it("does not count a rank it is about to fetch again", function()
            -- 8 kyu is checkpointed with 2 dropped; 7 kyu is not, and its
            -- earlier partial drops were never saved.
            stored[CHECKPOINT] = {
                timestamp = os.time() - 60,
                ranks = { ["-8"] = { { slug = "eight" } } },
                dropped = { ["-8"] = 2, ["-7"] = 9 },
            }
            page_script = with_dropped({ [1] = 1 })
            run()
            assert.are.equal(1, #warned, vim.inspect(warned))
            assert.truthy(warned[1]:find("3", 1, true), warned[1])
        end)

        it("resumes from a checkpoint written before dropped counts, with no warning from it", function()
            stored[CHECKPOINT] = {
                timestamp = os.time() - 60,
                ranks = { ["-8"] = { { slug = "eight" } }, ["-7"] = { { slug = "seven" } } },
            }
            page_script = with_dropped({})
            local items, partial = run()
            assert.is_nil(partial)
            assert.are.equal(-6, requested[1].rank)
            assert.are.equal("eight", items[1].slug)
            assert.are.same({}, warned)
            -- And the checkpoint it goes on to write has the field.
            assert.is_table(last_checkpoint().dropped)
        end)

        it("ignores a dropped field that is not a table of counts", function()
            for _, bad in ipairs({ "lots", 7, { ["-8"] = "many" } }) do
                warned, page_calls, requested = {}, 0, {}
                stored[CHECKPOINT] = {
                    timestamp = os.time() - 60,
                    ranks = { ["-8"] = { { slug = "eight" } } },
                    dropped = bad,
                }
                page_script = with_dropped({})
                local _, partial = run()
                assert.is_nil(partial)
                assert.are.same({}, warned, vim.inspect(bad))
            end
        end)

        it("stays quiet when a resume drops nothing anywhere", function()
            stored[CHECKPOINT] = {
                timestamp = os.time() - 60,
                ranks = { ["-8"] = { { slug = "eight" } } },
                dropped = { ["-8"] = 0 },
            }
            page_script = with_dropped({})
            run()
            assert.are.same({}, warned)
        end)
    end)
end)

-- A stale list is still served; only its refresh moves to the background.
describe("cache.problemlist stale list", function()
    local updates

    before_each(function()
        updates = 0
        package.loaded["codewars.logger"] = {
            info = function() end, warn = function() end, error = function() end,
            err = function() end, debug = function() end,
        }
        package.loaded["codewars.logger.spinner"] = {
            start = function()
                return { update = function() end, success = function() end, error = function() end }
            end,
        }
        package.loaded["codewars.config"] = { user = { cache = { update_interval = 100 } }, lang = "python" }
        package.loaded["codewars.cache.utils"] = {
            cache_file = function(name) return "mem:" .. name end,
            read_json = function() return { timestamp = os.time() - 500, items = { { slug = "old" } } } end,
            write_json = function() end,
        }
        package.loaded["codewars.api.search"] = {
            fetch_page = function(_, _, cb)
                updates = updates + 1
                return cb({ { slug = "new", id = "new" } }, false)
            end,
        }
        package.loaded["codewars.cache.problemlist"] = nil
    end)

    it("returns the old items flagged stale, with their age", function()
        local items, stale, age = require("codewars.cache.problemlist").get()
        assert.equals("old", items[1].slug)
        assert.is_true(stale)
        assert.is_true(age >= 500)
    end)

    it("refresh_if_stale rebuilds once in the background", function()
        local problemlist = require("codewars.cache.problemlist")
        problemlist.PACE_MS = 0
        assert.is_true(problemlist.refresh_if_stale())
        vim.wait(2000, function() return updates > 0 end)
        assert.is_true(updates > 0)
    end)

    it("does nothing for a fresh list", function()
        package.loaded["codewars.cache.utils"].read_json = function()
            return { timestamp = os.time(), items = { { slug = "fresh" } } }
        end
        local problemlist = require("codewars.cache.problemlist")
        assert.is_false(problemlist.refresh_if_stale())
        assert.equals(0, updates)
    end)
end)

-- Rebuilding ~290 pages to learn about a handful of new kata wastes minutes
-- under the rate limit. Between full builds, the list is kept current by
-- reading the "Newest" listing -- new kata, and kata that changed -- until a
-- page brings nothing it does not already have.
describe("cache.problemlist daily check", function()
    local LIST = "mem:problemlist.json"
    local DAY = 86400
    local stored, writes, requested, page_script, said

    local function kata(id, extra)
        return vim.tbl_extend("force", {
            id = id, slug = id, name = "Kata " .. id, rank_id = -8, rank_name = "8 kyu",
            languages = { "python" }, satisfaction = 90,
        }, extra or {})
    end

    --- A list built `age` seconds ago and, unless given, never checked since.
    local function list_of(items, age, checked_age)
        return {
            items = items,
            timestamp = os.time() - age,
            checked_at = checked_age and os.time() - checked_age or nil,
        }
    end

    local function ids(items)
        return vim.tbl_map(function(i) return i.id end, items)
    end

    local function list_writes()
        return vim.tbl_filter(function(w) return w.path == LIST end, writes)
    end

    local function settle()
        vim.wait(200, function() return false end)
    end

    local problemlist

    before_each(function()
        stored, writes, requested, said = {}, {}, {}, {}
        package.loaded["codewars.logger"] = setmetatable({}, {
            __index = function(_, level)
                return function(msg) said[#said + 1] = { level = level, msg = tostring(msg) } end
            end,
        })
        package.loaded["codewars.logger.spinner"] = {
            start = function()
                return { update = function() end, success = function() end, error = function() end }
            end,
        }
        package.loaded["codewars.config"] = {
            user = { cache = { update_interval = 30 * DAY, check_interval = DAY } }, lang = "python",
        }
        package.loaded["codewars.cache.utils"] = {
            cache_file = function(name) return "mem:" .. name end,
            read_json = function(path) return vim.deepcopy(stored[path]) end,
            write_json = function(path, data)
                writes[#writes + 1] = { path = path, data = vim.deepcopy(data) }
                stored[path] = vim.deepcopy(data)
                return true
            end,
        }
        package.loaded["codewars.api.search"] = {
            fetch_page = function(opts, page, cb)
                requested[#requested + 1] = { page = page, opts = opts }
                return cb(page_script(page))
            end,
        }
        package.loaded["codewars.cache.problemlist"] = nil
        problemlist = require("codewars.cache.problemlist")
        problemlist.PACE_MS = 0
    end)

    it("merges in kata it has never seen, a day after the last look", function()
        stored[LIST] = list_of({ kata("a"), kata("b") }, 2 * DAY)
        page_script = function(page)
            if page == 0 then return { kata("c"), kata("a") }, true end
            return { kata("a"), kata("b") }, true
        end

        assert.is_false(problemlist.refresh_if_stale(), "a fresh list is not rebuilt")
        settle()

        local w = list_writes()
        assert.equals(1, #w)
        assert.same({ "a", "b", "c" }, ids(w[1].data.items))
        assert.equals(stored[LIST].timestamp, w[1].data.timestamp, "the full build's age is kept")
        assert.is_true(os.time() - w[1].data.checked_at < 5)
    end)

    it("reads the Newest listing, across every language and rank", function()
        stored[LIST] = list_of({ kata("a") }, 2 * DAY)
        page_script = function() return { kata("a") }, true end

        problemlist.refresh_if_stale()
        settle()

        local opts = requested[1].opts
        assert.equals("sort_date+desc", opts.order)
        assert.equals("", opts.language)
        assert.is_nil(opts.rank)
    end)

    it("updates a kata whose name, rank or languages changed", function()
        stored[LIST] = list_of({ kata("a"), kata("b"), kata("c") }, 2 * DAY)
        page_script = function(page)
            if page == 0 then
                return {
                    kata("a", { name = "Renamed" }),
                    kata("b", { rank_id = -6, rank_name = "6 kyu" }),
                    kata("c", { languages = { "python", "rust" } }),
                }, true
            end
            return { kata("a", { name = "Renamed" }) }, true
        end

        problemlist.refresh_if_stale()
        settle()

        local items = list_writes()[1].data.items
        assert.same({ "a", "b", "c" }, ids(items), "updated in place, not added again")
        assert.equals("Renamed", items[1].name)
        assert.equals(-6, items[2].rank_id)
        assert.same({ "python", "rust" }, items[3].languages)
    end)

    it("stops at the first page that brings nothing new or changed", function()
        stored[LIST] = list_of({ kata("a"), kata("b") }, 2 * DAY)
        page_script = function(page)
            if page == 0 then return { kata("c") }, true end
            if page == 1 then return { kata("a"), kata("b") }, true end
            return { kata("d") }, true
        end

        problemlist.refresh_if_stale()
        settle()

        assert.equals(2, #requested)
        assert.same({ "a", "b", "c" }, ids(list_writes()[1].data.items))
    end)

    -- Satisfaction moves with every vote; counting it would read every
    -- check to its page limit.
    it("does not count a satisfaction change as a change", function()
        stored[LIST] = list_of({ kata("a") }, 2 * DAY)
        page_script = function(page)
            if page == 0 then return { kata("a", { satisfaction = 12 }) }, true end
            return { kata("z") }, true
        end

        problemlist.refresh_if_stale()
        settle()

        assert.equals(1, #requested)
    end)

    it("reads no more than CHECK_MAX_PAGES pages, leaving the rest to the full rebuild", function()
        stored[LIST] = list_of({}, 2 * DAY)
        page_script = function(page) return { kata("new" .. page) }, true end

        problemlist.refresh_if_stale()
        settle()

        assert.equals(problemlist.CHECK_MAX_PAGES, #requested)
        assert.equals(problemlist.CHECK_MAX_PAGES, #list_writes()[1].data.items)
    end)

    it("says how many kata it added or updated, and nothing when there were none", function()
        stored[LIST] = list_of({ kata("a") }, 2 * DAY)
        page_script = function(page)
            if page == 0 then return { kata("b"), kata("a", { name = "Renamed" }) }, true end
            return { kata("a", { name = "Renamed" }) }, true
        end
        problemlist.refresh_if_stale()
        settle()
        local msg = (said[#said] or {}).msg or ""
        assert.truthy(msg:find("1 new", 1, true) and msg:find("1 updated", 1, true), msg)

        said = {}
        stored[LIST].checked_at = os.time() - 2 * DAY
        page_script = function() return { kata("a", { name = "Renamed" }), kata("b") }, true end
        problemlist.refresh_if_stale()
        settle()
        assert.same({}, vim.tbl_filter(function(s) return s.level == "info" end, said))
        assert.equals(2, #list_writes(), "the look itself is still recorded")
    end)

    it("does not look again within a day of the last look", function()
        stored[LIST] = list_of({ kata("a") }, 10 * DAY, DAY / 2)
        page_script = function() return { kata("b") }, true end

        problemlist.refresh_if_stale()
        settle()

        assert.equals(0, #requested)
    end)

    it("looks right away at a list built more than a day ago and never checked", function()
        stored[LIST] = list_of({ kata("a") }, DAY + 60)
        page_script = function() return { kata("a") }, true end

        problemlist.refresh_if_stale()
        settle()

        assert.equals(1, #requested)
    end)

    it("leaves a stale list to the full rebuild", function()
        stored[LIST] = list_of({ kata("a") }, 31 * DAY)
        page_script = function(page) return page == 0 and { kata("a") } or {}, page == 0 end

        assert.is_true(problemlist.refresh_if_stale())
        settle()

        for _, r in ipairs(requested) do
            assert.are_not.equal("sort_date+desc", r.opts.order)
        end
    end)

    it("does nothing when there is no list yet", function()
        page_script = function() return { kata("a") }, true end
        assert.is_false(problemlist.check_for_new())
        assert.equals(0, #requested)
    end)

    -- A failed look leaves checked_at alone, so the next open tries again.
    it("writes nothing when a page fails", function()
        stored[LIST] = list_of({ kata("a") }, 2 * DAY)
        page_script = function(page)
            if page == 0 then return { kata("b") }, true end
            return {}, false, { msg = "HTTP 503" }
        end

        problemlist.refresh_if_stale()
        settle()

        assert.equals(0, #list_writes())
    end)

    local function warnings()
        return vim.tbl_filter(function(s) return s.level == "warn" end, said)
    end

    -- A page of results that parses to nothing is the markup moving, not a
    -- quiet day. The look stops, says so, and merges nothing -- not even the
    -- kata an earlier page read.
    it("stops with a warning, and merges nothing, when a page's markup drifted", function()
        stored[LIST] = list_of({ kata("a") }, 2 * DAY)
        page_script = function(page)
            if page == 0 then return { kata("b") }, true end
            return {}, false, { drift = true, msg = "30 results, none readable" }
        end

        problemlist.refresh_if_stale()
        settle()

        assert.equals(0, #list_writes())
        assert.equals(2, #requested, "carried on past the drifted page")
        local warns = warnings()
        assert.equals(1, #warns, vim.inspect(said))
        assert.truthy(warns[1].msg:find("markup may have changed", 1, true), warns[1].msg)
    end)

    it("looks again at the next open after a drifted page", function()
        stored[LIST] = list_of({ kata("a") }, 2 * DAY)
        page_script = function() return {}, false, { drift = true, msg = "none readable" } end

        problemlist.refresh_if_stale()
        settle()

        assert.is_nil(stored[LIST].checked_at)
        assert.is_true(problemlist.check_for_new())
        settle() -- let that look finish before the next test resets the stubs
    end)

    it("warns once with the total when pages dropped some blocks, and still merges", function()
        stored[LIST] = list_of({ kata("a") }, 2 * DAY)
        page_script = function(page)
            if page == 0 then return { kata("b") }, true, nil, 2 end
            if page == 1 then return { kata("c") }, true, nil, 3 end
            return { kata("a") }, true, nil, 0
        end

        problemlist.refresh_if_stale()
        settle()

        assert.same({ "a", "b", "c" }, ids(list_writes()[1].data.items))
        local warns = warnings()
        assert.equals(1, #warns, vim.inspect(said))
        assert.truthy(warns[1].msg:find("5", 1, true), warns[1].msg)
    end)

    it("does not warn when no block was dropped", function()
        stored[LIST] = list_of({ kata("a") }, 2 * DAY)
        page_script = function() return { kata("b") }, true, nil, 0 end

        problemlist.refresh_if_stale()
        settle()

        assert.equals(0, #warnings())
    end)

    -- "Nothing new on this page" only holds for a page that was read whole.
    -- Blocks the parser dropped could be the new kata, and the page after
    -- them may hold more that can be read.
    describe("when a page left blocks out", function()
        local CHECKED = 2 * DAY -- how long ago the list was last looked at

        it("goes on to the next page even though every readable entry is unchanged", function()
            stored[LIST] = list_of({ kata("a"), kata("b") }, 10 * DAY, CHECKED)
            page_script = function(page)
                if page == 0 then return { kata("a"), kata("b") }, true, nil, 1 end
                if page == 1 then return { kata("c"), kata("d") }, true, nil, 0 end
                return { kata("a") }, true, nil, 0
            end

            problemlist.refresh_if_stale()
            settle()

            assert.is_true(#requested >= 2, "stopped at the page that dropped a block")
            assert.same({ "a", "b", "c", "d" }, ids(list_writes()[1].data.items))
        end)

        it("merges what it read but does not record the look as complete", function()
            stored[LIST] = list_of({ kata("a") }, 10 * DAY, CHECKED)
            local checked_before = stored[LIST].checked_at
            page_script = function(page)
                if page == 0 then return { kata("a") }, true, nil, 1 end
                if page == 1 then return { kata("c") }, true, nil, 0 end
                return { kata("a") }, true, nil, 0
            end

            problemlist.refresh_if_stale()
            settle()

            local w = list_writes()
            assert.equals(1, #w)
            assert.same({ "a", "c" }, ids(w[1].data.items))
            assert.equals(checked_before, w[1].data.checked_at, "checked_at was advanced")
        end)

        it("looks again at the next open", function()
            stored[LIST] = list_of({ kata("a") }, 10 * DAY, CHECKED)
            page_script = function() return { kata("a") }, true, nil, 1 end

            problemlist.refresh_if_stale()
            settle()

            assert.equals(0, #list_writes(), "nothing was merged, so nothing should be written")
            assert.is_true(problemlist.check_for_new())
            settle() -- let that look finish before the next test resets the stubs
        end)

        it("stops at the page limit when every page left some out, merging the readable ones", function()
            stored[LIST] = list_of({ kata("a") }, 10 * DAY, CHECKED)
            local checked_before = stored[LIST].checked_at
            page_script = function(page) return { kata("new" .. page) }, true, nil, 1 end

            problemlist.refresh_if_stale()
            settle()

            assert.equals(problemlist.CHECK_MAX_PAGES, #requested)
            local w = list_writes()
            assert.equals(1, #w)
            assert.equals(1 + problemlist.CHECK_MAX_PAGES, #w[1].data.items)
            assert.equals(checked_before, w[1].data.checked_at, "checked_at was advanced")
        end)

        it("warns once with the total however many pages left some out", function()
            stored[LIST] = list_of({ kata("a") }, 10 * DAY, CHECKED)
            page_script = function() return { kata("a") }, true, nil, 2 end

            problemlist.refresh_if_stale()
            settle()

            assert.equals(problemlist.CHECK_MAX_PAGES, #requested)
            local warns = warnings()
            assert.equals(1, #warns, vim.inspect(said))
            assert.truthy(warns[1].msg:find(tostring(2 * problemlist.CHECK_MAX_PAGES), 1, true), warns[1].msg)
        end)

        it("stops at the last page the listing has, without waiting for the limit", function()
            stored[LIST] = list_of({ kata("a") }, 10 * DAY, CHECKED)
            page_script = function() return { kata("a") }, false, nil, 1 end

            problemlist.refresh_if_stale()
            settle()

            assert.equals(1, #requested)
        end)
    end)

    -- The other side of it: a page read whole, with nothing new on it, is
    -- still the end of the look, and the look is recorded.
    it("still stops at a clean page with nothing new, and records the look", function()
        stored[LIST] = list_of({ kata("a") }, 10 * DAY, 2 * DAY)
        page_script = function() return { kata("a") }, true, nil, 0 end

        problemlist.refresh_if_stale()
        settle()

        assert.equals(1, #requested)
        local w = list_writes()
        assert.equals(1, #w)
        assert.is_true(os.time() - w[1].data.checked_at < 5, "checked_at was not advanced")
    end)

    it("does not overwrite a list rebuilt while it was looking", function()
        stored[LIST] = list_of({ kata("a") }, 2 * DAY)
        page_script = function(page)
            if page == 0 then
                -- A full build lands between this page and the next.
                stored[LIST] = list_of({ kata("a"), kata("x") }, 0)
                return { kata("b") }, true
            end
            return { kata("a") }, true
        end

        problemlist.refresh_if_stale()
        settle()

        assert.equals(0, #list_writes())
    end)

    it("runs one look at a time", function()
        stored[LIST] = list_of({ kata("a") }, 2 * DAY)
        page_script = function() return { kata("a") }, true end

        assert.is_true(problemlist.check_for_new())
        assert.is_false(problemlist.check_for_new())
        settle()

        assert.equals(1, #requested)
    end)
end)

-- What the kata-list build paces itself with, shared with the other lookups
-- that have to stay under Codewars' ~60 requests a minute.
describe("cache.problemlist pacing helpers", function()
    local problemlist = require("codewars.cache.problemlist")
    local uv = vim.uv or vim.loop
    local saved, timers

    before_each(function()
        saved = {
            defer_fn = vim.defer_fn,
            pace = problemlist.PACE_MS,
            max_pace = problemlist.MAX_PACE_MS,
            cooldown = problemlist.COOLDOWN_MS,
            max_cooldown = problemlist.MAX_COOLDOWN_MS,
        }
        problemlist.PACE_MS, problemlist.MAX_PACE_MS = 1100, 2000
        problemlist.COOLDOWN_MS, problemlist.MAX_COOLDOWN_MS = 15000, 60000
        timers = {}
        vim.defer_fn = function(fn, ms) timers[#timers + 1] = { fn = fn, ms = ms } end
    end)

    after_each(function()
        vim.defer_fn = saved.defer_fn
        problemlist.PACE_MS, problemlist.MAX_PACE_MS = saved.pace, saved.max_pace
        problemlist.COOLDOWN_MS, problemlist.MAX_COOLDOWN_MS = saved.cooldown, saved.max_cooldown
    end)

    it("doubles the cooldown after each refusal in a row, up to its ceiling", function()
        local waits = vim.tbl_map(problemlist.cooldown_ms, { 1, 2, 3, 4 })
        assert.are.same({ 15000, 30000, 60000, 60000 }, waits)
    end)

    it("slows the pace by a quarter after a refusal, up to its ceiling", function()
        assert.are.equal(1375, problemlist.slower(1100))
        assert.are.equal(2000, problemlist.slower(1900))
    end)

    it("runs the first request at once and holds each later one to the pace", function()
        local paced = problemlist.pacer(function() return 1000 end, function() return false end)
        local ran = 0
        paced(function() ran = ran + 1 end)
        assert.are.equal(0, timers[1].ms)
        timers[1].fn()
        paced(function() ran = ran + 1 end)
        assert.is_true(timers[2].ms > 900 and timers[2].ms <= 1000, timers[2].ms)
        timers[2].fn()
        assert.are.equal(2, ran)
    end)

    it("waits out the pace before a first request when one has just been sent", function()
        local paced = problemlist.pacer(function() return 1000 end, function() return false end, uv.now())
        paced(function() end)
        assert.is_true(timers[1].ms > 900 and timers[1].ms <= 1000, timers[1].ms)
    end)

    it("sends nothing once cancelled, even if it was already waiting", function()
        local cancelled, ran = false, false
        local paced = problemlist.pacer(function() return 1000 end, function() return cancelled end)
        paced(function() ran = true end)
        cancelled = true
        timers[1].fn()
        assert.is_false(ran)
    end)
end)
