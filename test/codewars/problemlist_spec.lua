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
