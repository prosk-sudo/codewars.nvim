-- The identity cache exists to skip the /dashboard hop at launch: that page
-- is ~112KB of session-rendered HTML fetched purely to learn a username, and
-- its latency is the menu's worst case. Caching it is only safe because every
-- read is bound to the cookie that produced it -- see the fingerprint tests.
describe("Profile cache", function()
    local Path = require("plenary.path")
    local dir, profile, Cookie

    local function reload()
        for _, m in ipairs({
            "codewars.cache.utils",
            "codewars.cache.cookie",
            "codewars.cache.profile",
        }) do
            package.loaded[m] = nil
        end
        local real = require("codewars.cache.utils")
        package.loaded["codewars.cache.utils"] = vim.tbl_extend("force", real, {
            cache_file = function(name) return Path:new(dir .. "/" .. name) end,
        })
        for _, m in ipairs({ "codewars.cache.cookie", "codewars.cache.profile" }) do
            package.loaded[m] = nil
        end
        Cookie = require("codewars.cache.cookie")
        profile = require("codewars.cache.profile")
    end

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        reload()
    end)

    after_each(function()
        for _, m in ipairs({
            "codewars.cache.utils",
            "codewars.cache.cookie",
            "codewars.cache.profile",
        }) do
            package.loaded[m] = nil
        end
        vim.fn.delete(dir, "rf")
    end)

    local function sign_in(session)
        assert.is_nil(Cookie.set(("CSRF-TOKEN=tok; _session_id=%s"):format(session)))
    end

    describe("round-trip", function()
        it("returns what was saved while the cookie is unchanged", function()
            sign_in("session-one")
            assert.is_true(profile.save({
                username = "prosk",
                lang = "rust",
                honor = 851,
                rank_name = "4 kyu",
                completed = 215,
            }))

            local got = profile.get()
            assert.is_not_nil(got)
            assert.are.equal("prosk", got.username)
            assert.are.equal("rust", got.lang)
            assert.are.equal(851, got.honor)
            assert.are.equal("4 kyu", got.rank_name)
            assert.are.equal(215, got.completed)
        end)

        it("survives a fresh require, so a later launch reads it back", function()
            sign_in("session-one")
            profile.save({ username = "prosk", lang = "rust" })

            reload()
            assert.are.equal("prosk", profile.get().username)
        end)
    end)

    -- The load-bearing property. Cookie.identity_changed() only fires for
    -- changes made THROUGH the plugin; the cookie file is plain text in the
    -- cache dir, so a hand-edit, a restored dotfile backup or a synced cache
    -- directory swaps the account without any hook running. Binding each read
    -- to the live session is what stops a cached name from being served for
    -- someone else's cookie -- the failure ccb634e fixed for config-set
    -- usernames, arriving from a stale file instead.
    describe("cookie binding", function()
        it("refuses a profile saved under a different session", function()
            sign_in("session-one")
            profile.save({ username = "alice" })

            -- Swap the cookie file directly: no plugin code path, no hook.
            Path:new(dir .. "/cookie"):write("CSRF-TOKEN=tok; _session_id=session-two", "w")
            reload()

            assert.is_nil(profile.get())
        end)

        it("refuses to read when signed out entirely", function()
            sign_in("session-one")
            profile.save({ username = "prosk" })

            Path:new(dir .. "/cookie"):rm()
            reload()

            assert.is_nil(profile.get())
        end)

        it("refuses to save when there is no cookie to bind to", function()
            assert.is_false(profile.save({ username = "prosk" }))
            assert.is_nil(profile.get())
        end)

        it("does not store the session id itself", function()
            sign_in("super-secret-session")
            profile.save({ username = "prosk" })

            local raw = Path:new(dir .. "/profile.json"):read()
            assert.is_nil(raw:find("super-secret-session", 1, true),
                "the raw session id must never be duplicated into a second file")
        end)
    end)

    -- A cached username is interpolated straight into /api/v1/users/%s, and
    -- it also keys the completed cache. It comes off disk, so validate it on
    -- the way in rather than trusting whatever the file holds.
    describe("username validation", function()
        it("accepts the shapes Codewars actually issues", function()
            sign_in("session-one")
            for _, name in ipairs({ "prosk", "some_user", "some-user", "some.user", "u1" }) do
                assert.is_true(profile.save({ username = name }), name .. " should be accepted")
                assert.are.equal(name, profile.get().username)
            end
        end)

        it("refuses to save a username that is not one", function()
            sign_in("session-one")
            for _, bad in ipairs({
                "", "../../etc/passwd", "has space", "sl/ash", "quer?y", "ha#sh", ("x"):rep(65),
            }) do
                assert.is_false(profile.save({ username = bad }),
                    ("%q should be refused"):format(bad))
            end
        end)

        it("refuses to read a file whose username went bad", function()
            sign_in("session-one")
            profile.save({ username = "prosk" })

            local raw = vim.json.decode(Path:new(dir .. "/profile.json"):read())
            raw.username = "../../etc/passwd"
            Path:new(dir .. "/profile.json"):write(vim.json.encode(raw), "w")

            assert.is_nil(profile.get())
        end)
    end)

    -- The record is filled from two different responses: /dashboard knows the
    -- username and language, /api/v1/users knows the stats. Whichever lands
    -- second must not blank what the first learned.
    describe("update", function()
        it("merges into what is already stored", function()
            sign_in("session-one")
            profile.save({ username = "prosk", lang = "rust" })

            assert.is_true(profile.update({ honor = 851, completed = 215 }))

            local got = profile.get()
            assert.are.equal("prosk", got.username)
            assert.are.equal("rust", got.lang, "the stats write must not drop the language")
            assert.are.equal(851, got.honor)
            assert.are.equal(215, got.completed)
        end)

        it("can fill in the username when nothing is stored yet", function()
            sign_in("session-one")
            assert.is_true(profile.update({ username = "prosk", honor = 1 }))
            assert.are.equal("prosk", profile.get().username)
        end)

        it("refuses when there is no username anywhere", function()
            sign_in("session-one")
            assert.is_false(profile.update({ honor = 851 }))
        end)
    end)

    describe("clearing", function()
        it("clear() drops it", function()
            sign_in("session-one")
            profile.save({ username = "prosk" })
            profile.clear()
            assert.is_nil(profile.get())
        end)

        it("survives a missing file", function()
            assert.has_no.errors(function() profile.clear() end)
        end)

        -- identity_changed() is the single enumerated place for identity-scoped
        -- state. A profile left behind there would be served to the next
        -- account on the very next launch.
        it("a new cookie clears it", function()
            sign_in("session-one")
            profile.save({ username = "alice" })

            sign_in("session-two")
            assert.is_nil(profile.get())
        end)

        it("signing out clears it", function()
            sign_in("session-one")
            profile.save({ username = "alice" })

            Cookie.delete()
            assert.is_nil(profile.get())
            assert.is_false(Path:new(dir .. "/profile.json"):exists())
        end)
    end)

    describe("malformed files", function()
        it("a truncated file reads as absent rather than throwing", function()
            sign_in("session-one")
            Path:new(dir .. "/profile.json"):write('{"username": "pro', "w")
            assert.is_nil(profile.get())
        end)

        it("a file with no fingerprint reads as absent", function()
            sign_in("session-one")
            Path:new(dir .. "/profile.json"):write('{"username":"prosk"}', "w")
            assert.is_nil(profile.get())
        end)
    end)
end)
