-- The partial-cache guard is the crux of the rate-limit work: a truncated
-- list stamped with the current time looks fresh for the whole cache
-- interval and hides every kata the aborted run never fetched. Nothing
-- exercised problemlist.update before this file.
describe("cache.problemlist update", function()
    package.loaded["codewars.logger"] = {
        info = function() end, warn = function() end, error = function() end,
        err = function() end, debug = function() end,
    }
    package.loaded["codewars.logger.spinner"] = {
        start = function()
            return {
                update = function() end,
                success = function() end,
                error = function() end,
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
