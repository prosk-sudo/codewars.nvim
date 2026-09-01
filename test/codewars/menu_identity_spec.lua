-- The menu header used to wait on a /dashboard scrape before it could show
-- anything -- the slowest request the plugin makes, for a username that cannot
-- change while the session lasts. These cover the cached path that replaced
-- it, and the checks that keep a cached identity honest.
describe("Menu identity", function()
    local config = {
        user = { keys = { toggle = { "q" } }, username = "", lang = "python" },
        lang = "python",
        lang_persisted = false,
        langs = require("codewars.config.langs"),
        name = "codewars.nvim",
    }
    package.loaded["codewars.config"] = config
    package.loaded["codewars.logger"] = setmetatable({}, {
        __index = function() return function() end end,
    })
    package.loaded["codewars.cache.cookie"] = {
        get = function() return { csrf_token = "t", session_id = "s", str = "" } end,
        identity_changed = function() config.identity_cleared = true end,
    }

    package.loaded["codewars-ui.renderer.menu"] = nil
    local Menu = require("codewars-ui.renderer.menu")
    _Cw_state = _Cw_state or {}

    local calls, stored, api_stub, profile_stub

    -- A profile payload as /api/v1/users returns it.
    local function payload(honor, completed, rank)
        return {
            honor = honor,
            ranks = { overall = { name = rank or "4 kyu" } },
            codeChallenges = { totalCompleted = completed },
        }
    end

    before_each(function()
        calls, stored = {}, nil
        config.user.username = ""
        config.lang = "python"
        config.user.lang = "python"
        config.lang_persisted = false
        config.identity_cleared = nil

        api_stub = {
            -- Overridden per test; default is a healthy account.
            current = { username = "prosk", current_language = "rust" },
            profile = payload(851, 215),
            err = nil,
            get = function(username, cb)
                table.insert(calls, "get:" .. username)
                cb(api_stub.err and nil or api_stub.profile, api_stub.err)
            end,
            get_current = function(cb)
                table.insert(calls, "get_current")
                cb(api_stub.current)
            end,
        }
        profile_stub = {
            get = function() return stored and vim.deepcopy(stored) end,
            save = function(d) stored = vim.deepcopy(d); return true end,
            update = function(f)
                stored = vim.tbl_extend("force", stored or {}, f)
                return true
            end,
            clear = function() stored = nil; return true end,
        }
        package.loaded["codewars.api.user"] = api_stub
        package.loaded["codewars.cache.profile"] = profile_stub
    end)

    after_each(function()
        package.loaded["codewars.api.user"] = nil
        package.loaded["codewars.cache.profile"] = nil
        Menu._active = nil
    end)

    --- Drive fetch_user_data through its only public seam and drain the
    --- vim.schedule callbacks it posts.
    local function fetch(menu)
        Menu._active = menu or { _stats = nil }
        Menu.refresh_stats()
        vim.wait(50, function() return false end)
        return Menu._active
    end

    describe("a cached identity", function()
        it("paints the numbers without touching the dashboard", function()
            stored = { username = "prosk", lang = "rust", honor = 851,
                rank_name = "4 kyu", completed = 215 }

            local m = fetch()

            assert.are.equal("prosk", config.user.username)
            assert.are.equal(851, m._stats.honor)
            assert.are.equal("4 kyu", m._stats.rank_name)
            assert.is_false(vim.tbl_contains(calls, "get_current"),
                "the dashboard must not be on the cached path")
        end)

        it("re-applies the auto-detected language, which is never persisted", function()
            stored = { username = "prosk", lang = "rust", honor = 1 }
            fetch()
            assert.are.equal("rust", config.lang)
        end)

        it("leaves a language the user chose alone", function()
            config.lang_persisted = true
            config.lang = "python"
            stored = { username = "prosk", lang = "rust", honor = 1 }
            fetch()
            assert.are.equal("python", config.lang)
        end)
    end)

    describe("no cached identity", function()
        it("falls back to the dashboard, then caches what it found", function()
            local m = fetch()

            assert.are.same({ "get_current", "get:prosk" }, calls)
            assert.are.equal("prosk", config.user.username)
            assert.are.equal("rust", config.lang)
            assert.are.equal("prosk", stored.username)
            assert.are.equal("rust", stored.lang)
            assert.are.equal(851, stored.honor)
            assert.are.equal(215, m._stats.completed)
        end)
    end)

    -- An account renamed under a cookie that still works. Nothing else detects
    -- it: the public endpoint 404s and the row would stay empty for good.
    describe("a cached name that stopped resolving", function()
        it("drops the cache and re-detects from the session", function()
            stored = { username = "old-name", honor = 851 }
            local real_get = api_stub.get
            api_stub.get = function(username, cb)
                -- Only the stale name 404s; the re-detected one works.
                if username == "old-name" then
                    table.insert(calls, "get:" .. username)
                    return cb(nil, { status = 404, msg = "not found" })
                end
                return real_get(username, cb)
            end

            local m = fetch()

            assert.are.same({ "get:old-name", "get_current", "get:prosk" }, calls)
            assert.are.equal("prosk", config.user.username)
            assert.are.equal("prosk", stored.username)
            assert.are.equal(851, m._stats.honor)
        end)

        it("keeps a cached name that failed for any other reason", function()
            stored = { username = "prosk", honor = 851 }
            api_stub.err = { status = 500, msg = "server error" }

            fetch()

            assert.are.same({ "get:prosk" }, calls, "a 500 is not a rename")
            assert.are.equal("prosk", stored.username)
        end)
    end)

    -- The row used to be emitted only once the numbers arrived, which changed
    -- the line count and with it the centring pad, so the whole block jumped
    -- as the fetch landed.
    describe("the reserved stats row", function()
        local function render_lines(stats)
            vim.cmd("tabnew")
            local menu = Menu:init()
            menu:mount()
            menu._stats = stats
            menu._redraw_only = true
            menu:draw()
            local lines = vim.api.nvim_buf_get_lines(menu.bufnr, 0, -1, false)
            vim.cmd("tabclose!")
            return lines
        end

        it("holds the block still whether or not the numbers have arrived", function()
            local empty = render_lines(nil)
            local filled = render_lines({ rank_name = "4 kyu", honor = 851, completed = 215 })

            assert.are.equal(#empty, #filled,
                "the line count must not change when stats arrive")

            local shown = table.concat(filled, "\n")
            assert.truthy(shown:find("4 kyu", 1, true))
            assert.truthy(shown:find("851 honor", 1, true))
            assert.truthy(shown:find("215 kata completed", 1, true))
            assert.is_nil(table.concat(empty, "\n"):find("honor", 1, true))
        end)
    end)

    -- refresh_stats bumps the count so it does not lag the submit. That guess
    -- must never reach disk: a failed refetch would bake it in permanently.
    describe("the optimistic count after a submit", function()
        it("is shown but not persisted", function()
            stored = { username = "prosk", lang = "rust", honor = 851,
                rank_name = "4 kyu", completed = 215 }
            api_stub.err = { status = 500, msg = "server error" }

            local m = fetch({ _stats = { rank_name = "4 kyu", honor = 851, completed = 215 } })

            assert.are.equal(216, m._stats.completed, "the screen should show the bump")
            assert.are.equal(215, stored.completed, "the cache must keep the server's count")
        end)

        it("survives the cache seeding that follows it", function()
            stored = { username = "prosk", honor = 851, rank_name = "4 kyu", completed = 215 }
            api_stub.err = { status = 500, msg = "server error" }

            local m = fetch({ _stats = { rank_name = "4 kyu", honor = 851, completed = 215 } })

            assert.are.equal(216, m._stats.completed,
                "seeding from cache must not overwrite fresher in-memory stats")
        end)
    end)
end)
