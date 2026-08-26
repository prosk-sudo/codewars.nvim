-- The completed cache must never be stamped "fresh" from a partial or
-- misunderstood reply, and a kata solved while a refresh was in flight must
-- not be un-completed by that refresh.
local function quiet_logger()
    package.loaded["codewars.logger"] = {
        info = function() end, warn = function() end, error = function() end,
        err = function() end, debug = function() end,
    }
    package.loaded["codewars.logger.spinner"] = {
        start = function()
            return { update = function() end, success = function() end, error = function() end }
        end,
    }
end

describe("cache.completed", function()
    local store, completed, script

    before_each(function()
        quiet_logger()
        store = {}
        package.loaded["codewars.config"] = {
            user = { cache = { update_interval = 100 }, username = "me" },
            lang = "python",
        }
        package.loaded["codewars.cache.utils"] = {
            cache_file = function(name) return "mem:" .. name end,
            read_json = function(path) return store[path] end,
            write_json = function(path, data) store[path] = vim.deepcopy(data) end,
        }
        package.loaded["codewars.api.urls"] = { completed = "/users/%s/completed?page=%d" }
        package.loaded["codewars.api.utils"] = {
            get = function(_, opts) return opts.callback(script()) end,
        }
        package.loaded["codewars.cache.completed"] = nil
        completed = require("codewars.cache.completed")
    end)

    it("mark keeps a missing or expired cache stale instead of stamping it fresh", function()
        completed.mark("k1", "kata-one", "python")
        assert.equals(0, store["mem:completed.json"].timestamp)
        local items, stale = completed.get()
        assert.equals("k1", items[1].id)
        assert.is_true(items[1].local_mark)
        assert.is_true(stale)
    end)

    it("update refuses a reply without `data` and hands back the cached list with an error", function()
        store["mem:completed.json"] = { timestamp = os.time(), items = { { id = "old" } } }
        script = function() return { totalPages = 1 } end
        local got, err
        completed.update(function(items, e) got, err = items, e end)
        assert.equals("old", got[1].id)
        assert.truthy(err and err.msg)
        assert.equals("old", store["mem:completed.json"].items[1].id)
    end)

    it("update passes a transport error to the callback", function()
        script = function() return nil, { msg = "boom", rate_limited = true } end
        local err
        completed.update(function(_, e) err = e end)
        assert.is_true(err.rate_limited)
    end)

    it("update keeps a kata marked locally while the refresh was in flight", function()
        completed.mark("new", "new-kata", "python")
        script = function() return { data = { { id = "server" } }, totalPages = 1 } end
        local got
        completed.update(function(items) got = items end)
        local ids = vim.tbl_map(function(i) return i.id end, got)
        assert.same({ "new", "server" }, ids)
        assert.is_true(store["mem:completed.json"].timestamp > 0)
    end)
end)

describe("cache.problemlist all-empty guard", function()
    it("does not write a cache when every search page parses as empty", function()
        quiet_logger()
        package.loaded["codewars.config"] = { user = { cache = {} }, lang = "python" }
        local writes = {}
        package.loaded["codewars.cache.utils"] = {
            cache_file = function(name) return "mem:" .. name end,
            read_json = function() return nil end,
            write_json = function(path, data) writes[#writes + 1] = { path = path, data = data } end,
        }
        package.loaded["codewars.api.search"] = {
            fetch_page = function(_, _, cb) return cb({}, false) end,
        }
        package.loaded["codewars.cache.problemlist"] = nil
        local problemlist = require("codewars.cache.problemlist")
        local got, partial
        problemlist.update({ max_pages = 2 }, function(items, p) got, partial = items, p end)
        vim.wait(2000, function() return got ~= nil end)
        assert.same({}, got)
        assert.is_true(partial)
        assert.same({}, writes)
    end)
end)
