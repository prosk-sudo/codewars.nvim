-- Signing in again after the session expired, as a user lives it: the
-- dashboard says "Session expired — :CW cookie", they run `:CW cookie`, paste
-- the two values, and the header should name them again.
--
-- Driven end to end through the REAL cookie cache, profile cache, command
-- table and menu. Only two things are stubbed: HTTP (codewars.api.user, the
-- way menu_identity_spec does) and the two input boxes (the way
-- cookie_prompt_spec does).
describe("signing in again after the session expired", function()
    local Path = require("plenary.path")
    local config = require("codewars.config")

    local OLD, NEW = ("a"):rep(32), ("b"):rep(32)
    local Cookie, profile, cmd, Menu, menu
    local scrapes, warnings, real_notify, real_ask, real_cache

    local function settle()
        vim.wait(150, function() return false end)
    end

    --- The identity row is the last line the menu draws.
    local function footer()
        local lines = vim.api.nvim_buf_get_lines(menu.bufnr, 0, -1, false)
        return vim.trim(lines[#lines])
    end

    local function rendered()
        return table.concat(vim.api.nvim_buf_get_lines(menu.bufnr, 0, -1, false), "\n")
    end

    --- Script the two input boxes.
    local function paste(csrf, session)
        local answers, i = { csrf, session }, 0
        cmd._ask_cookie_value = function(_, on_value)
            i = i + 1
            on_value(answers[i])
        end
    end

    local function open_menu()
        vim.cmd("tabnew")
        require("codewars").show_menu() -- what the first `:CW` does
        menu = _Cw_state.menu
        settle()
    end

    --- The state the user started from: a cookie Codewars no longer accepts,
    --- with the identity cached under it, and the dashboard open.
    local function mount_expired()
        assert.is_nil(Cookie.set(("CSRF-TOKEN=oldtoken; _session_id=%s"):format(OLD)))
        assert.is_true(profile.save({ username = "prosk", lang = "python",
            honor = 863, rank_name = "4 kyu", completed = 218 }))
        open_menu()
        assert.equals("Session expired — :CW cookie", footer())
    end

    before_each(function()
        real_cache = config.storage.cache
        local dir = Path:new(vim.fn.tempname())
        dir:mkdir({ parents = true })
        config.storage.cache = dir
        config.user.username = ""
        _Cw_state.menu = nil

        for _, m in ipairs({ "codewars.cache.cookie", "codewars.cache.profile",
            "codewars-ui.renderer.menu" }) do
            package.loaded[m] = nil
        end
        Menu = require("codewars-ui.renderer.menu")
        Cookie = require("codewars.cache.cookie")
        profile = require("codewars.cache.profile")
        cmd = require("codewars.command")
        cmd.setup() -- registers :CW
        real_ask = cmd._ask_cookie_value

        scrapes, warnings = {}, {}
        real_notify = vim.notify
        vim.notify = function(msg, level)
            if (level or 0) >= vim.log.levels.WARN then
                warnings[#warnings + 1] = tostring(msg)
            end
        end

        -- Codewars: the old session is bounced, the new one is alive.
        package.loaded["codewars.api.user"] = {
            get_current = function(cb)
                local c = Cookie.get()
                local sid = c and c.session_id
                scrapes[#scrapes + 1] = sid == NEW and "new" or "old"
                vim.schedule(function()
                    if sid == NEW then
                        cb({ username = "prosk", current_language = "python" })
                    else
                        cb(nil, { auth = true, msg = "Could not read your profile "
                            .. "from the Codewars dashboard. Run :CW cookie if your session expired." })
                    end
                end)
            end,
            get = function(_, cb)
                vim.schedule(function()
                    cb({ honor = 863, ranks = { overall = { name = "4 kyu" } },
                        codeChallenges = { totalCompleted = 218 } })
                end)
            end,
        }
    end)

    after_each(function()
        vim.notify = real_notify
        cmd._ask_cookie_value = real_ask
        package.loaded["codewars.api.user"] = nil
        config.storage.cache = real_cache
        Menu._active = nil
        _Cw_state.menu = nil
        pcall(vim.cmd, "tabonly!")
    end)

    it("`:CW cookie` puts the username back in the header", function()
        mount_expired()

        paste("newtoken", NEW)
        vim.cmd("CW cookie")
        settle()

        assert.equals(NEW, Cookie.get().session_id) -- the sign-in itself worked
        assert.equals("Signed in as: prosk", footer(),
            ("username=%q, dashboard requests=%s"):format(
                config.user.username, vim.inspect(scrapes)))
    end)

    it("`:CW cookie` asks Codewars who the new session belongs to", function()
        mount_expired()

        paste("newtoken", NEW)
        vim.cmd("CW cookie")
        settle()

        assert.same({ "old", "new" }, scrapes,
            "nothing re-detected the identity under the new cookie")
        assert.equals("prosk", config.user.username)
        assert.equals("prosk", (profile.get() or {}).username)
    end)

    -- One request, not two: the button used to run its own detection, and
    -- /dashboard is the slowest call the menu makes.
    it("the dashboard's own Cookie > Update button detects exactly once", function()
        mount_expired()
        paste("newtoken", NEW)

        menu.pages.cookie[1].fn() -- "Update"
        settle()

        assert.equals("Signed in as: prosk", footer())
        assert.equals("main", menu.page)
        assert.same({ "old", "new" }, scrapes)
    end)

    -- The numbers on screen belong to the session that fetched them: after
    -- an account switch, somebody else's. Gone from the moment the cookie
    -- is saved, not once the new ones happen to land -- if they never do,
    -- the old ones would stay for good.
    it("does not keep the previous session's stats after `:CW cookie`", function()
        mount_expired()
        menu._stats = { rank_name = "1 kyu", honor = 12345, completed = 999 }

        paste("newtoken", NEW)
        vim.cmd("CW cookie")
        assert.is_nil(rendered():find("12345 honor", 1, true), "the previous session's stats are still shown")

        settle()
        assert.truthy(rendered():find("863 honor", 1, true), "the new session's stats never arrived")
    end)

    -- Saving a cookie is not Codewars accepting it.
    it("a pasted cookie Codewars rejects reads as expired, not signed in", function()
        mount_expired()

        paste("stale", OLD)
        vim.cmd("CW cookie")
        settle()

        assert.equals("Session expired — :CW cookie", footer(),
            "warnings raised instead: " .. vim.inspect(warnings))
    end)

    -- Only verify() used to say "expired", and verify() only runs when a
    -- profile is cached. With none -- the state right after any sign-in --
    -- the same bounced session was painted as signed in.
    it("an expired cookie with no cached profile reads as expired", function()
        assert.is_nil(Cookie.set(("CSRF-TOKEN=oldtoken; _session_id=%s"):format(OLD)))
        open_menu()

        assert.equals("Session expired — :CW cookie", footer(),
            "warnings raised instead: " .. vim.inspect(warnings))
    end)

    -- cmd.with_auth: any auth-gated command run while signed out prompts for
    -- a cookie and resumes. The dashboard was left on its Sign In page.
    it("a sign-in prompted by another command reaches the dashboard", function()
        open_menu()
        assert.equals("signin", menu.page)
        assert.equals("codewars.com", footer())

        paste("newtoken", NEW)
        local ran = false
        cmd.with_auth(function() ran = true end)
        settle()

        assert.is_true(ran)
        assert.equals("main", menu.page)
        assert.equals("Signed in as: prosk", footer())
    end)

    it("`:CW cookie delete` reaches the dashboard", function()
        assert.is_nil(Cookie.set(("CSRF-TOKEN=newtoken; _session_id=%s"):format(NEW)))
        open_menu()
        assert.equals("Signed in as: prosk", footer())

        vim.cmd("CW cookie delete")
        settle()

        assert.is_nil(Cookie.get())
        assert.equals("signin", menu.page)
        assert.equals("codewars.com", footer())
    end)

    -- Cookie.delete() told the menu BEFORE removing the file. From the
    -- expired state that redrew, the redraw read the cookie back, and the
    -- module re-cached the very cookie it was deleting.
    it("signing out of an expired session really signs out", function()
        mount_expired()

        vim.cmd("CW cookie delete")
        settle()

        assert.is_nil(Cookie.get(), "the deleted cookie is still served from memory")
        assert.equals("codewars.com", footer())
    end)
end)
