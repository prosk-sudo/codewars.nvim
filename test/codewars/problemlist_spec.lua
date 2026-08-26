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
    package.loaded["codewars.cache.utils"] = {
        cache_file = function(name) return "/tmp/cw-test-" .. tostring(name) end,
        read_json = function() return nil end,
        write_json = function(path, data) table.insert(writes, { path = path, data = data }) end,
    }

    -- One scripted response per page request, consumed in order.
    local page_calls = 0
    local page_script = nil
    package.loaded["codewars.api.search"] = {
        fetch_page = function(_, _, cb)
            page_calls = page_calls + 1
            return cb(page_script(page_calls))
        end,
    }

    package.loaded["codewars.cache.problemlist"] = nil
    local problemlist = require("codewars.cache.problemlist")

    local function run()
        local done, items, partial = false, nil, nil
        problemlist.update({ max_pages = 2 }, function(i, p)
            items, partial, done = i, p, true
        end)
        vim.wait(8000, function() return done end)
        assert.is_true(done, "update never called back")
        return items, partial
    end

    before_each(function()
        writes = {}
        page_calls = 0
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
        assert.are.equal(1, #writes)
        assert.is_true(#items > 0)
        assert.is_not_nil(writes[1].data.timestamp)
    end)

    -- Refusing the write is the whole point: the next run must retry rather
    -- than trust a short list.
    it("does NOT write the cache when rate limiting aborts the run", function()
        page_script = function(n)
            if n == 1 then return { { slug = "kata-1" } }, true, nil end
            return {}, false, { status = 429, rate_limited = true, msg = "limited" }
        end
        local items, partial = run()
        assert.are.equal(0, #writes, "a partial cache was written")
        assert.is_true(partial)
        assert.is_not_nil(items) -- caller still receives what was collected
    end)

    it("does NOT write the cache when auth aborts the run", function()
        page_script = function(n)
            if n == 1 then return { { slug = "kata-1" } }, true, nil end
            return {}, false, { auth = true, msg = "session expired" }
        end
        local _, partial = run()
        assert.are.equal(0, #writes, "a partial cache was written")
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
        assert.are.equal(0, #writes, "a partial cache was written")
        assert.is_true(partial)
        assert.are.equal(1, #items)
    end)

    it("tells fetch_page to stop retrying once the run is aborted", function()
        local cancelled
        package.loaded["codewars.api.search"].fetch_page = function(opts, _, cb)
            cancelled = cancelled or opts.cancelled
            page_calls = page_calls + 1
            return cb(page_script(page_calls))
        end
        page_script = function(n)
            if n == 1 then return { { slug = "kata-1" } }, true, nil end
            return {}, false, { status = 429, rate_limited = true, msg = "limited" }
        end
        assert.is_false(cancelled and cancelled() or false)
        run()
        assert.is_function(cancelled)
        assert.is_true(cancelled())
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
