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
    local fp -- fingerprint of the live cookie

    -- A profile payload as /api/v1/users returns it.
    local function payload(honor, completed, rank)
        return {
            honor = honor,
            ranks = { overall = { name = rank or "4 kyu" } },
            codeChallenges = { totalCompleted = completed },
        }
    end

    before_each(function()
        calls, stored, fp = {}, nil, "alice-session"
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
        -- Mirrors the real module: a save binds the record to whatever cookie
        -- is live AT WRITE TIME, and a record bound to another one reads as
        -- absent. Getting that ordering right is what makes the stale-reply
        -- tests below meaningful.
        profile_stub = {
            fingerprint = function() return fp end,
            get = function()
                if stored and stored.fp == fp then return vim.deepcopy(stored) end
                return nil
            end,
            save = function(d)
                stored = vim.tbl_extend("force", vim.deepcopy(d), { fp = fp })
                return true
            end,
            update = function(f)
                return profile_stub.save(vim.tbl_extend("force", profile_stub.get() or {}, f))
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
            stored = { fp = "alice-session", username = "prosk", lang = "rust", honor = 851,
                rank_name = "4 kyu", completed = 215 }

            local m = fetch()

            assert.are.equal("prosk", config.user.username)
            assert.are.equal(851, m._stats.honor)
            assert.are.equal("4 kyu", m._stats.rank_name)
            assert.is_false(vim.tbl_contains(calls, "get_current"),
                "the dashboard must not be on the cached path")
        end)

        it("re-applies the auto-detected language, which is never persisted", function()
            stored = { fp = "alice-session", username = "prosk", lang = "rust", honor = 1 }
            fetch()
            assert.are.equal("rust", config.lang)
        end)

        it("leaves a language the user chose alone", function()
            config.lang_persisted = true
            config.lang = "python"
            stored = { fp = "alice-session", username = "prosk", lang = "rust", honor = 1 }
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
            stored = { fp = "alice-session", username = "old-name", honor = 851 }
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
            stored = { fp = "alice-session", username = "prosk", honor = 851 }
            api_stub.err = { status = 500, msg = "server error" }

            fetch()

            assert.are.same({ "get:prosk" }, calls, "a 500 is not a rename")
            assert.are.equal("prosk", stored.username)
        end)
    end)

    -- profile.save() stamps a record with whatever cookie is live when it
    -- LANDS, while the request closed over the username it was ISSUED for.
    -- A reply that outlives its identity therefore rebinds the old account to
    -- the new session -- the exact ccb634e hazard the fingerprint exists to
    -- prevent, reached through a path it does not cover.
    describe("a reply that outlived its session", function()
        --- Issue a stats request but hold its reply until the test lands it.
        local function hold(for_name)
            local land
            local real = api_stub.get
            api_stub.get = function(username, cb)
                table.insert(calls, "get:" .. username)
                if username == for_name then
                    land = function() cb(api_stub.profile, nil) end
                else
                    return real(username, cb)
                end
            end
            return function() land() ; vim.wait(50, function() return false end) end
        end

        it("is dropped when the cookie changed under it", function()
            stored = { fp = "alice-session", username = "alice", lang = "rust",
                honor = 851, rank_name = "4 kyu", completed = 215 }
            local land = hold("alice")

            fetch()

            -- Signed in as somebody else while alice's stats were outstanding.
            profile_stub.clear()
            config.user.username = ""
            fp = "bob-session"

            land()

            assert.is_nil(stored,
                "alice must not be cached under bob's fingerprint")
            assert.are.equal("", config.user.username)
        end)

        -- The cookie never changes here, so the fingerprint cannot catch it:
        -- an account renamed under a live session, healed while the old name's
        -- stats were still in flight.
        it("is dropped when the name is no longer ours", function()
            stored = { fp = "alice-session", username = "old-name",
                honor = 851, rank_name = "4 kyu", completed = 215 }
            local land = hold("old-name")

            fetch()

            config.user.username = "new-name"
            profile_stub.update({ username = "new-name", honor = 10 })

            land()

            assert.are.equal("new-name", stored.username,
                "a reply for the old name must not overwrite the healed record")
            assert.are.equal(10, stored.honor)
        end)
    end)

    -- The row used to be emitted only once the numbers arrived, which changed
    -- the line count and with it the centring pad, so the whole block jumped
    -- as the fetch landed.
    -- The 404 self-heal blanks config.user.username before re-detecting. A
    -- verify() reply landing inside that window compares the dashboard name
    -- against "", reads it as a different account, and runs the full identity
    -- purge -- dropping session ids and the focus kata belonging to the very
    -- account it is about to restore.
    --
    -- Driven through _fetch_user_data because verify() only runs at mount;
    -- refresh_stats never sets opts.verify, so the seam used elsewhere in this
    -- file cannot reach this path at all.
    describe("a rename healing while verify is in flight", function()
        it("does not purge the identity it is only re-detecting", function()
            stored = { fp = "alice-session", username = "old-name", honor = 851 }
            local purged = 0
            local cookie = package.loaded["codewars.cache.cookie"]
            local real_changed = cookie.identity_changed
            cookie.identity_changed = function() purged = purged + 1 end

            local land_verify
            local first = true
            api_stub.get_current = function(cb)
                table.insert(calls, "get_current")
                if first then
                    first = false
                    -- verify's request: held until the heal has blanked the name
                    land_verify = function() cb({ username = "prosk", current_language = "rust" }) end
                else
                    cb({ username = "prosk", current_language = "rust" })
                end
            end
            api_stub.get = function(username, cb)
                table.insert(calls, "get:" .. username)
                if username == "old-name" then
                    return cb(nil, { status = 404, msg = "not found" })
                end
                cb(api_stub.profile, nil)
            end

            local m = { _stats = nil }
            Menu._fetch_user_data(m, nil, { verify = true })
            vim.wait(50, function() return false end)

            land_verify()
            vim.wait(50, function() return false end)

            cookie.identity_changed = real_changed
            assert.are.equal("prosk", config.user.username)
            assert.are.equal(0, purged,
                "the same account was re-detected, not swapped: nothing should be purged")
        end)
    end)

    -- The 404 heal and verify() both want /dashboard -- the slowest request
    -- here. detect() had a single-flight flag, but verify() never consulted it,
    -- so the pair the flag existed for was never actually deduplicated.
    describe("a heal racing a verification", function()
        --- Both requests go out at mount and the 404 lands afterwards, which
        --- is the real ordering: the stats API answers in ~0.3s and the
        --- dashboard in 0.85-15s. Replying synchronously would invert it --
        --- the heal would fire before verify() was even called, and the test
        --- would pass while exercising the opposite path.
        local function race(verify_reply)
            local scrapes, land_verify, land_404 = 0, nil, nil
            api_stub.get_current = function(cb)
                scrapes = scrapes + 1
                if scrapes == 1 then
                    land_verify = function() cb(verify_reply()) end
                else
                    cb({ username = "new-name", current_language = "rust" })
                end
            end
            api_stub.get = function(u, cb)
                table.insert(calls, "get:" .. u)
                if u == "old-name" then
                    land_404 = function() cb(nil, { status = 404, msg = "nf" }) end
                else
                    cb(api_stub.profile, nil)
                end
            end
            stored = { fp = "alice-session", username = "old-name", honor = 851 }

            Menu._fetch_user_data({ _stats = nil }, nil, { verify = true })
            vim.wait(50, function() return false end)
            assert.are.equal(1, scrapes, "verify should have issued the only scrape so far")

            land_404()
            vim.wait(50, function() return false end)
            local at_404 = scrapes

            land_verify()
            vim.wait(50, function() return false end)
            return at_404, scrapes
        end

        it("scrapes the dashboard once, not twice", function()
            local at_404, total = race(function()
                return { username = "new-name", current_language = "rust" }
            end)
            assert.are.equal(1, at_404, "the heal must not start a second scrape")
            assert.are.equal(1, total)
            assert.are.equal("new-name", config.user.username,
                "the verification must finish the heal it absorbed")
        end)

        -- If the scrape the heal deferred to comes back empty, the name is
        -- still missing and something has to go and get it.
        it("falls back to detecting when that scrape fails", function()
            local _, total = race(function() return nil, { msg = "boom" } end)
            assert.are.equal(2, total, "a failed verification must not strand the heal")
            assert.are.equal("new-name", config.user.username)
        end)
    end)

    -- A dead session used to produce a dashboard that painted the cached name
    -- and stats as if signed in, plus a one-shot warning saying the opposite.
    -- The stats are public, so the cache refreshes happily with no session at
    -- all; the screen and the warning contradicted each other on every launch.
    describe("an expired session", function()
        local function verify_replies_with(err)
            api_stub.get_current = function(cb)
                table.insert(calls, "get_current")
                cb(nil, err)
            end
        end

        local function mounted_with_cache()
            stored = { fp = "alice-session", username = "prosk", lang = "rust",
                honor = 863, rank_name = "4 kyu", completed = 218 }
            vim.cmd("tabnew")
            local menu = Menu:init()
            menu:mount()
            vim.wait(50, function() return false end)
            return menu
        end

        local function rendered(menu)
            return table.concat(vim.api.nvim_buf_get_lines(menu.bufnr, 0, -1, false), "\n")
        end

        it("is shown in the header instead of being painted as signed in", function()
            verify_replies_with({ auth = true, msg = "Could not read your profile" })
            local menu = mounted_with_cache()

            assert.is_true(menu._session_expired == true)
            local text = rendered(menu)
            assert.truthy(text:find("Session expired", 1, true), text)
            assert.truthy(text:find(":CW cookie", 1, true))
            assert.is_nil(text:find("Signed in as", 1, true),
                "a dead session must not be painted as signed in")
            assert.is_nil(text:find("863 honor", 1, true),
                "cached stats must not be painted as live")
            vim.cmd("tabclose!")
        end)

        -- A rate limit or a dropped connection says nothing about the session.
        it("is not declared on a network failure", function()
            verify_replies_with({ status = 429, rate_limited = true, msg = "rate limited" })
            local menu = mounted_with_cache()

            assert.is_nil(menu._session_expired)
            assert.truthy(rendered(menu):find("Signed in as", 1, true))
            vim.cmd("tabclose!")
        end)

        it("clears once a verification succeeds again", function()
            verify_replies_with({ auth = true, msg = "expired" })
            local menu = mounted_with_cache()
            assert.is_true(menu._session_expired == true)

            api_stub.get_current = function(cb)
                cb({ username = "prosk", current_language = "rust" })
            end
            Menu._fetch_user_data(menu, nil, { verify = true })
            vim.wait(50, function() return false end)

            assert.is_nil(menu._session_expired)
            vim.cmd("tabclose!")
        end)

        -- Signing in or out goes through identity_changed(), the one place that
        -- enumerates identity-scoped state; it has to reach the menu too, or
        -- the header keeps saying "expired" over a brand-new cookie.
        it("clears when the identity changes", function()
            verify_replies_with({ auth = true, msg = "expired" })
            local menu = mounted_with_cache()
            assert.is_true(menu._session_expired == true)

            _Cw_state.menu = menu
            Menu.session_changed()
            vim.wait(50, function() return false end)

            assert.is_nil(menu._session_expired)
            assert.is_nil(rendered(menu):find("Session expired", 1, true))
            vim.cmd("tabclose!")
        end)
    end)

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
            stored = { fp = "alice-session", username = "prosk", lang = "rust", honor = 851,
                rank_name = "4 kyu", completed = 215 }
            api_stub.err = { status = 500, msg = "server error" }

            local m = fetch({ _stats = { rank_name = "4 kyu", honor = 851, completed = 215 } })

            assert.are.equal(216, m._stats.completed, "the screen should show the bump")
            assert.are.equal(215, stored.completed, "the cache must keep the server's count")
        end)

        it("survives the cache seeding that follows it", function()
            stored = { fp = "alice-session", username = "prosk", honor = 851, rank_name = "4 kyu", completed = 215 }
            api_stub.err = { status = 500, msg = "server error" }

            local m = fetch({ _stats = { rank_name = "4 kyu", honor = 851, completed = 215 } })

            assert.are.equal(216, m._stats.completed,
                "seeding from cache must not overwrite fresher in-memory stats")
        end)
    end)
end)
