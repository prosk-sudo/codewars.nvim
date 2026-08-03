describe("cmd.focus", function()
    package.loaded["codewars.config"] = {
        user = { keys = { toggle = { "q" } }, logging = false, debug = false, username = "prosk" },
        lang = "python",
        langs = {
            { slug = "python", lang = "Python", ft = "py", comment = "#" },
            { slug = "go", lang = "Go", ft = "go", comment = "//" },
        },
    }

    local logged = {}
    package.loaded["codewars.logger"] = {
        info = function(m) table.insert(logged, { "info", m }) end,
        warn = function(m) table.insert(logged, { "warn", m }) end,
        error = function(m) table.insert(logged, { "error", m }) end,
        err = function(e) table.insert(logged, { "err", e }) end,
        debug = function() end,
    }

    package.loaded["codewars.utils"] = {
        auth_guard = function() end,
        get_lang = function(slug)
            return (slug == "python" or slug == "go") and { slug = slug } or nil
        end,
        resolve_lang_arg = function(slug)
            local li = (slug == "python" or slug == "go") and { slug = slug } or nil
            if not li then
                package.loaded["codewars.logger"].error(("Unknown language: %s"):format(slug))
            end
            return li
        end,
        parse_slug = function(s) return s end,
    }

    -- Kata UI stub: record every mount
    local mounts = {}
    package.loaded["codewars-ui.kata"] = {
        new = function(_, slug, lang)
            return {
                mount = function() table.insert(mounts, { slug = slug, lang = lang }) end,
            }
        end,
    }

    -- Trainer stub: serves a numbered kata per call so freshness is observable
    local trainer_calls = {}
    local skip_calls = {}
    local trainer_response = { err = nil }
    package.loaded["codewars.api.trainer"] = {
        STRATEGIES = {
            fundamentals = "reference_workout",
            rank_up = "default",
            practice_and_repeat = "retrain_workout",
            beta = "beta_workout",
        },
        next_kata = function(cat, lang, cb)
            table.insert(trainer_calls, { cat = cat, lang = lang })
            if trainer_response.err then
                return cb(nil, trainer_response.err)
            end
            cb({ slug = "served-kata-" .. #trainer_calls })
        end,
        skip = function(cat, lang, cb)
            table.insert(skip_calls, { cat = cat, lang = lang })
            if trainer_response.err then
                return cb(nil, trainer_response.err)
            end
            cb({ slug = "skipped-to-kata-" .. #skip_calls })
        end,
    }

    -- Random path stub
    local random_calls = {}
    package.loaded["codewars.cache.problemlist_utils"] = {
        random_for_lang = function(lang)
            table.insert(random_calls, lang)
            return { slug = "random-kata" }, nil
        end,
    }

    -- Picker stub: immediately yield canned choices
    local picker_choices = { lang = "python", category = "rank_up" }
    package.loaded["codewars.picker"] = {
        pick_language = function(cb) cb(picker_choices.lang) end,
        focus_category = function(cb) cb(picker_choices.category) end,
    }

    package.loaded["codewars.command"] = nil
    local cmd = require("codewars.command")

    before_each(function()
        logged = {}
        mounts = {}
        trainer_calls = {}
        skip_calls = {}
        random_calls = {}
        trainer_response = { err = nil }
    end)

    it("direct args: peeks the trainer and mounts", function()
        cmd.focus({ _positional = { "python", "rank_up" } })
        assert.are.same({ cat = "rank_up", lang = "python" }, trainer_calls[1])
        assert.are.same({ slug = "served-kata-1", lang = "python" }, mounts[1])
    end)

    it("re-running the same focus peeks again (the server decides what it returns)", function()
        cmd.focus({ _positional = { "python", "fundamentals" } })
        cmd.focus({ _positional = { "python", "fundamentals" } })
        cmd.focus({ _positional = { "python", "fundamentals" } })
        assert.are.equal(3, #trainer_calls)
        assert.are.equal(0, #skip_calls) -- re-running never skips
    end)

    it("random resolves client-side, never touching the trainer", function()
        cmd.focus({ _positional = { "python", "random" } })
        assert.are.equal(0, #trainer_calls)
        assert.are.same({ "python" }, random_calls)
        assert.are.same({ slug = "random-kata", lang = "python" }, mounts[1])
    end)

    it("rejects a single positional arg without a category (no silent no-op)", function()
        cmd.focus({ _positional = { "python" } })
        assert.are.equal(0, #trainer_calls)
        assert.are.equal(0, #mounts)
        assert.are.equal("error", logged[1][1])
        assert.truthy(logged[1][2]:match("Usage"))
    end)

    it("rejects an unknown language", function()
        cmd.focus({ _positional = { "klingon", "rank_up" } })
        assert.are.equal(0, #trainer_calls)
        assert.are.equal(0, #mounts)
        assert.are.equal("error", logged[1][1])
        assert.truthy(logged[1][2]:match("Unknown language"))
    end)

    it("rejects an unknown category", function()
        cmd.focus({ _positional = { "python", "hardcore" } })
        assert.are.equal(0, #trainer_calls)
        assert.are.equal("error", logged[1][1])
        assert.truthy(logged[1][2]:match("Unknown focus category"))
    end)

    it("no args: chains language picker → category picker → run", function()
        picker_choices = { lang = "go", category = "beta" }
        cmd.focus({})
        assert.are.same({ cat = "beta", lang = "go" }, trainer_calls[1])
        assert.are.same({ slug = "served-kata-1", lang = "go" }, mounts[1])
        picker_choices = { lang = "python", category = "rank_up" }
    end)

    it("trainer errors are reported, nothing mounts", function()
        trainer_response = { err = { msg = "boom" } }
        cmd.focus({ _positional = { "python", "beta" } })
        assert.are.equal(0, #mounts)
        local last = logged[#logged]
        assert.are.equal("err", last[1])
        assert.are.equal("boom", last[2].msg)
    end)

    it(":CW exec routes 'focus python rank_up' to cmd.focus", function()
        cmd.exec({ name = "CW", args = "focus python rank_up" })
        assert.are.same({ cat = "rank_up", lang = "python" }, trainer_calls[1])
        assert.are.same({ slug = "served-kata-1", lang = "python" }, mounts[1])
    end)

    it("skip: advances the last focus and mounts the next kata", function()
        cmd.focus({ _positional = { "python", "rank_up" } })
        cmd.focus_skip()
        assert.are.same({ cat = "rank_up", lang = "python" }, skip_calls[1])
        assert.are.same({ slug = "skipped-to-kata-1", lang = "python" }, mounts[2])
    end)

    it("skip without a prior focus errors instead of guessing", function()
        -- Fresh module instance: _last_focus must start unset.
        package.loaded["codewars.command"] = nil
        local fresh = require("codewars.command")
        fresh.focus_skip()
        assert.are.equal(0, #skip_calls)
        local last = logged[#logged]
        assert.are.equal("error", last[1])
        assert.truthy(last[2]:match("No focus to skip"))
    end)

    it("skip with a random focus re-rolls client-side", function()
        cmd.focus({ _positional = { "python", "random" } })
        cmd.focus_skip()
        assert.are.equal(2, #random_calls)
        assert.are.equal(0, #skip_calls)
        assert.are.same({ slug = "random-kata", lang = "python" }, mounts[2])
    end)

    it("skip errors are reported, nothing mounts", function()
        cmd.focus({ _positional = { "python", "beta" } })
        trainer_response = { err = { msg = "skip-boom" } }
        cmd.focus_skip()
        assert.are.equal(1, #mounts) -- only the initial focus mount
        local last = logged[#logged]
        assert.are.equal("err", last[1])
        assert.are.equal("skip-boom", last[2].msg)
    end)

    it(":CW exec routes 'focus skip' to cmd.focus_skip", function()
        cmd.focus({ _positional = { "go", "beta" } })
        cmd.exec({ name = "CW", args = "focus skip" })
        assert.are.same({ cat = "beta", lang = "go" }, skip_calls[1])
        assert.are.same({ slug = "skipped-to-kata-1", lang = "go" }, mounts[2])
    end)
end)
