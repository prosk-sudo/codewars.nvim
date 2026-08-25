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
        -- Mirrors the real utils.kata_tabp: a tabpage for the instance's
        -- winid, nil when that window is gone. Deliberately keyed off the
        -- fake winid rather than _Cw_state membership — those are separate
        -- facts in production, and a kata can be registered with a dead
        -- window.
        kata_tabp = function(k)
            if k and k.winid and not k._win_closed then return 1 end
        end,
    }

    -- Kata UI stub mirroring the real lifecycle in lua/codewars-ui/kata.lua:
    -- registration into _Cw_state.katas and the _on_mounted hook both happen
    -- in handle_mount, which the real mount() only reaches after two async
    -- API calls and NOT at all when it early-returns to a duplicate tab.
    -- `mount_outcome` switches between those cases so the async gap and the
    -- duplicate-tab short circuit are both testable.
    local mounts = {}
    local unmounts = {}
    local mount_outcome = "handle_mount" -- "handle_mount" | "duplicate" | "pending"
    local pending_mounts = {}
    -- NOTE: _Cw_state is a shared global; see TODOS.md for spec-isolation cleanup.
    _Cw_state = _Cw_state or {}
    _Cw_state.katas = _Cw_state.katas or {}
    package.loaded["codewars-ui.kata"] = {
        new = function(_, slug, lang)
            local k = { slug = slug, lang = lang }
            local function handle_mount()
                k.winid = 1000 + #mounts -- a live window, as create_buffer sets
                table.insert(_Cw_state.katas, k)
                if k._on_mounted then
                    local hook = k._on_mounted
                    k._on_mounted = nil
                    hook(k)
                end
            end
            k.mount = function()
                table.insert(mounts, { slug = slug, lang = lang })
                if mount_outcome == "duplicate" then
                    -- Jumped to an existing tab: never registers, never hooks.
                    return k
                elseif mount_outcome == "pending" then
                    -- Fetch still in flight; resolve later via finish_mounts().
                    table.insert(pending_mounts, handle_mount)
                    return k
                end
                handle_mount()
                return k
            end
            k.unmount = function()
                table.insert(unmounts, { slug = slug, lang = lang })
                _Cw_state.katas = vim.tbl_filter(function(x) return x ~= k end, _Cw_state.katas)
            end
            return k
        end,
    }

    --- Resolve every mount parked by mount_outcome == "pending".
    local function finish_mounts()
        local queued = pending_mounts
        pending_mounts = {}
        for _, fn in ipairs(queued) do fn() end
    end

    -- Trainer stub: serves a numbered kata per call so freshness is observable
    local trainer_calls = {}
    local skip_calls = {}
    local advance_calls = {}
    local trainer_response = { err = nil }
    -- Park a fetch mid-flight so a second command can be issued during the
    -- window where the first has not resolved.
    local trainer_hold = false
    local held_fetches = {}
    package.loaded["codewars.api.trainer"] = {
        STRATEGIES = {
            fundamentals = "reference_workout",
            rank_up = "default",
            practice_and_repeat = "retrain_workout",
            beta = "beta_workout",
        },
        next_kata = function(cat, lang, cb)
            table.insert(trainer_calls, { cat = cat, lang = lang })
            if trainer_hold then
                table.insert(held_fetches, function()
                    cb({ slug = "served-kata-" .. #trainer_calls })
                end)
                return
            end
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
        advance = function(cat, lang, expected, cb)
            table.insert(advance_calls, { cat = cat, lang = lang, expected = expected })
            if cb then cb(trainer_response.err) end
        end,
    }

    -- Random path stub
    local random_calls = {}
    local random_err = nil
    package.loaded["codewars.cache.problemlist_utils"] = {
        random_for_lang = function(lang)
            table.insert(random_calls, lang)
            if random_err then return nil, random_err end
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
        unmounts = {}
        trainer_calls = {}
        skip_calls = {}
        advance_calls = {}
        random_calls = {}
        trainer_response = { err = nil }
        mount_outcome = "handle_mount"
        pending_mounts = {}
        picker_choices = { lang = "python", category = "rank_up" }
        random_err = nil
        trainer_hold = false
        held_fetches = {}
        _Cw_state.katas = {}
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

    it("skip closes the kata it replaces (no lingering tab)", function()
        cmd.focus({ _positional = { "python", "rank_up" } })
        cmd.focus_skip()
        assert.are.same({ { slug = "served-kata-1", lang = "python" } }, unmounts)
        assert.are.equal(1, #_Cw_state.katas) -- only the replacement remains
        assert.are.equal("skipped-to-kata-1", _Cw_state.katas[1].slug)
    end)

    it("never closes a same-slug kata the user opened themselves", function()
        -- Kata:unmount force-deletes the buffer, discarding unsaved code, so
        -- the close must match the tracked INSTANCE and nothing else.
        cmd.focus({ _positional = { "python", "rank_up" } })
        -- Focus's own instance is gone (window closed), but a kata with the
        -- SAME slug is open because the user ran :CW train on it. A slug
        -- fallback would force-close theirs; identity matching must not.
        _Cw_state.katas[1]._win_closed = true
        local user_opened = { slug = "served-kata-1", lang = "python", kata_id = "served-kata-1", winid = 999 }
        user_opened.unmount = function()
            table.insert(unmounts, { slug = "USER-OPENED-SHOULD-NOT-CLOSE" })
        end
        table.insert(_Cw_state.katas, user_opened)
        cmd.focus_skip()
        assert.are.equal(0, #unmounts)
    end)

    it("does not close a tracked kata whose window is already gone", function()
        -- Registered in _Cw_state but the window died (user :q'd it). The
        -- real kata_tabp returns nil here, so there is nothing to close.
        cmd.focus({ _positional = { "python", "rank_up" } })
        _Cw_state.katas[1]._win_closed = true
        cmd.focus_skip()
        assert.are.equal(0, #unmounts)
    end)

    it("does not close the previous kata until the replacement is on screen", function()
        cmd.focus({ _positional = { "python", "rank_up" } })
        mount_outcome = "pending" -- replacement mount still in flight
        cmd.focus_skip()
        assert.are.equal(0, #unmounts) -- nothing closed yet
        finish_mounts()
        assert.are.same({ { slug = "served-kata-1", lang = "python" } }, unmounts)
    end)

    it("keeps the previous kata open when the replacement never mounts", function()
        -- Replacement 404s or jumps to a duplicate tab: closing anyway would
        -- leave the user with nothing.
        cmd.focus({ _positional = { "python", "rank_up" } })
        mount_outcome = "duplicate"
        cmd.focus_skip()
        assert.are.equal(0, #unmounts)
        assert.are.equal(1, #_Cw_state.katas)
    end)

    it("random skip that re-rolls the same kata does not close it", function()
        cmd.focus({ _positional = { "python", "random" } })
        mount_outcome = "duplicate" -- same kata already open → mount jumps to it
        cmd.focus_skip()
        assert.are.equal(0, #unmounts)
        assert.are.equal(1, #_Cw_state.katas)
    end)

    it("skip after the kata was closed manually just opens the next", function()
        cmd.focus({ _positional = { "python", "rank_up" } })
        _Cw_state.katas[1]._win_closed = true -- the user :q'd the kata tab
        cmd.focus_skip()
        assert.are.equal(0, #unmounts)
        assert.are.same({ slug = "skipped-to-kata-1", lang = "python" }, mounts[2])
    end)

    it("failed skip keeps the current kata open", function()
        cmd.focus({ _positional = { "python", "rank_up" } })
        trainer_response = { err = { msg = "boom" } }
        cmd.focus_skip()
        assert.are.equal(0, #unmounts) -- never close before the replacement is secured
        assert.are.equal(1, #_Cw_state.katas)
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

    it("skip with a random focus re-rolls client-side and closes the old one", function()
        cmd.focus({ _positional = { "python", "random" } })
        cmd.focus_skip()
        assert.are.equal(2, #random_calls)
        assert.are.equal(0, #skip_calls)
        assert.are.same({ slug = "random-kata", lang = "python" }, mounts[2])
        assert.are.same({ { slug = "random-kata", lang = "python" } }, unmounts)
        assert.are.equal(1, #_Cw_state.katas)
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

    it("finalizing the focus kata advances the queue (solve does not move it)", function()
        cmd.focus({ _positional = { "python", "fundamentals" } })
        cmd.focus_kata_completed(_Cw_state.katas[1])
        assert.are.equal(1, #advance_calls)
        assert.are.equal("fundamentals", advance_calls[1].cat)
        assert.are.equal("python", advance_calls[1].lang)
        -- advance re-checks the head before popping, so it needs to know
        -- which kata this is retiring.
        assert.are.equal("served-kata-1", advance_calls[1].expected.slug)
    end)

    it("finalizing a kata matched by hex id also advances (peek returns id only)", function()
        cmd.focus({ _positional = { "python", "rank_up" } })
        -- The mounted kata keeps the served id in kata_id and gets a readable
        -- slug back from the API, so id matching has to work on its own.
        cmd.focus_kata_completed({ slug = "readable-name", kata_id = "served-kata-1", lang = "python" })
        assert.are.equal(1, #advance_calls)
        assert.are.equal("rank_up", advance_calls[1].cat)
        assert.are.equal("served-kata-1", advance_calls[1].expected.id)
    end)

    it("finalizing an unrelated kata does not advance the queue", function()
        cmd.focus({ _positional = { "python", "fundamentals" } })
        cmd.focus_kata_completed({ slug = "some-other-kata", lang = "python" })
        assert.are.equal(0, #advance_calls)
    end)

    it("finalizing in a different language does not advance the queue", function()
        cmd.focus({ _positional = { "python", "fundamentals" } })
        cmd.focus_kata_completed({ slug = "served-kata-1", lang = "go" })
        assert.are.equal(0, #advance_calls)
    end)

    it("an empty problem list warns and mounts nothing", function()
        random_err = "Problem list empty. Run :CW cache update first."
        cmd.focus({ _positional = { "python", "random" } })
        assert.are.equal(0, #mounts)
        local last = logged[#logged]
        assert.are.equal("warn", last[1])
        assert.truthy(tostring(last[2]):match("cache update"))
    end)

    it("a random skip with an empty problem list keeps the current kata open", function()
        cmd.focus({ _positional = { "python", "random" } })
        random_err = "Problem list empty. Run :CW cache update first."
        cmd.focus_skip()
        assert.are.equal(0, #unmounts) -- no replacement, so nothing is closed
        assert.are.equal(1, #_Cw_state.katas)
    end)

    -- The dequeue a skip issues is irreversible, so the record it reads must
    -- never describe a focus that failed to load.
    it("a second focus during an in-flight fetch is refused, not silently queued", function()
        trainer_hold = true
        cmd.focus({ _positional = { "python", "fundamentals" } })
        cmd.focus({ _positional = { "go", "beta" } })
        assert.are.equal(1, #trainer_calls) -- the second never reached the API
        local last = logged[#logged]
        assert.are.equal("warn", last[1])
        assert.truthy(last[2]:match("Already fetching"))

        -- Release the parked fetch: the in-flight flag lives in the command
        -- module, so leaving it set would refuse every focus in later tests.
        trainer_hold = false
        for _, resolve in ipairs(held_fetches) do resolve() end
    end)

    it("a refused second focus cannot redirect a later skip to the wrong queue", function()
        trainer_hold = true
        cmd.focus({ _positional = { "python", "fundamentals" } })
        cmd.focus({ _positional = { "go", "beta" } }) -- refused
        trainer_hold = false
        for _, resolve in ipairs(held_fetches) do resolve() end

        cmd.focus_skip()
        -- The skip must target the focus that actually loaded (python /
        -- fundamentals), never the rejected go / beta.
        assert.are.same({ cat = "fundamentals", lang = "python" }, skip_calls[1])
    end)

    it("the in-flight guard releases after a failed fetch", function()
        trainer_response = { err = { msg = "boom" } }
        cmd.focus({ _positional = { "python", "fundamentals" } })
        trainer_response = { err = nil }
        cmd.focus({ _positional = { "python", "fundamentals" } })
        assert.are.equal(2, #trainer_calls)
        assert.are.equal(1, #mounts)
    end)

    it("a nil kata never advances the queue", function()
        cmd.focus({ _positional = { "python", "rank_up" } })
        cmd.focus_kata_completed(nil)
        assert.are.equal(0, #advance_calls)
    end)

    it("a random focus has no server queue to advance", function()
        cmd.focus({ _positional = { "python", "random" } })
        cmd.focus_kata_completed(_Cw_state.katas[1])
        assert.are.equal(0, #advance_calls)
    end)

    it("a failed advance is swallowed (self-heal covers it next focus)", function()
        cmd.focus({ _positional = { "python", "beta" } })
        trainer_response = { err = { msg = "advance-boom" } }
        assert.has_no.errors(function()
            cmd.focus_kata_completed(_Cw_state.katas[1])
        end)
        assert.are.equal(1, #advance_calls)
    end)

    it("skip after a completed advance does not close an already-consumed kata", function()
        cmd.focus({ _positional = { "python", "fundamentals" } })
        cmd.focus_kata_completed(_Cw_state.katas[1])
        cmd.focus_skip()
        assert.are.equal(0, #unmounts) -- the solved kata stays open for review
        assert.are.same({ slug = "skipped-to-kata-1", lang = "python" }, mounts[2])
    end)

    it(":CW exec routes 'focus skip' to cmd.focus_skip", function()
        cmd.focus({ _positional = { "go", "beta" } })
        cmd.exec({ name = "CW", args = "focus skip" })
        assert.are.same({ cat = "beta", lang = "go" }, skip_calls[1])
        assert.are.same({ slug = "skipped-to-kata-1", lang = "go" }, mounts[2])
    end)

    -- An identity change calls forget_focus: the remembered kata belongs to
    -- the previous account's queue, so a skip afterwards must not act on it.
    it("forget_focus clears a populated focus so skip has nothing to act on", function()
        cmd.focus({ _positional = { "python", "rank_up" } })
        assert.are.same({ lang = "python", category = "rank_up", slug = "served-kata-1" }, cmd.current_focus())
        cmd.forget_focus()
        assert.is_nil(cmd.current_focus())
        cmd.focus_skip()
        assert.are.equal(0, #skip_calls, "skip acted on a forgotten focus")
    end)
end)
