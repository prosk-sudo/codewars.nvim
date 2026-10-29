-- Submit eligibility: only a full attempt, registered with Codewars, on the
-- session it was run against, may unlock :CW submit.
describe("Runner submit eligibility", function()
    local warnings, infos = {}, {}
    package.loaded["codewars.logger"] = {
        debug = function() end, err = function() end, error = function() end,
        info = function(msg) infos[#infos + 1] = msg end,
        warn = function(msg) warnings[#warnings + 1] = msg end,
    }

    -- Finalize goes through api.utils; count it instead of sending it, and
    -- stub what a successful finalize touches afterwards.
    local finalized = 0
    package.loaded["codewars.api.utils"] = {
        post = function(_, opts)
            finalized = finalized + 1
            opts.callback({ success = true })
        end,
    }
    package.loaded["codewars.api.urls"] = { finalize = "/finalize/%s/%s", base = "" }
    package.loaded["codewars.cache.completed"] = { mark = function() end }
    package.loaded["codewars.picker"] = { invalidate_completed_cache = function() end }
    package.loaded["codewars-ui.renderer.menu"] = { refresh_stats = function() end }
    package.loaded["codewars.command"] = { focus_kata_completed = function() end }
    package.loaded["codewars-ui.popup.solutions"] = { fetch_and_show = function() end }
    package.loaded["codewars.config"] = { user = { debug = false }, lang = "python" }

    -- Scripted transport: the spec drives every callback by hand.
    local pending = {}
    package.loaded["codewars.api.attempt"] = {
        submit = function(_, _, _, _, solution_id, _, _, cb)
            pending.submit = { solution_id = solution_id, cb = cb }
        end,
        notify = function(project_id, solution_id, _, cb)
            pending.notify = { project_id = project_id, solution_id = solution_id, cb = cb }
        end,
    }
    package.loaded["codewars.runner"] = nil
    local Runner = require("codewars.runner")

    local function kata()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "print(1)" })
        return {
            bufnr = bufnr, lang = "python", slug = "k", project_id = "p1", solution_id = "s1",
            example_fixture = "test", last_attempt_success = false,
        }
    end

    before_each(function()
        -- A queued submit re-enters through a scheduled call. Let anything a
        -- previous test left scheduled run out BEFORE the counters reset, or
        -- its finalize lands in this test's numbers.
        vim.wait(50, function() return false end)
        pending = {}
        warnings, infos = {}, {}
        finalized = 0
        Runner.running = false
    end)

    --- A passing attempt whose registration is still in flight.
    local function passed_attempt(k)
        Runner.running = false
        Runner:init(k):handle("attempt")
        pending.submit.cb({ result = { completed = true }, token = "t" })
        return pending.notify.cb
    end

    local function submit(k)
        Runner.running = false
        Runner:init(k):handle("submit")
    end

    -- The queued submit re-enters through Runner.run, which is scheduled.
    local function settle()
        vim.wait(100, function() return false end)
    end

    it("a passing quick test does not unlock submit", function()
        local k = kata()
        Runner:init(k):handle("test")
        pending.submit.cb({ result = { completed = true }, token = "t" })
        assert.is_false(k.last_attempt_success)
    end)

    it("a passing attempt unlocks submit only once Codewars has registered it", function()
        local k = kata()
        local register = passed_attempt(k)
        assert.is_true(k.last_attempt_success)
        assert.equals(1, k._notify_pending)

        submit(k)
        assert.equals(0, finalized, "finalized before Codewars registered the attempt")

        register({ success = true })
        assert.equals(0, k._notify_pending)
        vim.wait(100, function() return false end)
        assert.equals(1, finalized)
    end)

    -- Submitting inside that window used to be refused with "try again in a
    -- moment", and the console sat on "Submitting..." while the user guessed
    -- when to retry. The plugin knows exactly when it is safe; it waits.
    describe("a submit made while the attempt is still registering", function()
        it("goes through on its own once Codewars registers it", function()
            local k = kata()
            local register = passed_attempt(k)

            submit(k)
            assert.equals(0, finalized)
            assert.is_nil(warnings[1], "waiting is not a warning: " .. tostring(warnings[1]))
            assert.truthy((infos[#infos] or ""):find("Waiting for Codewars", 1, true), infos[#infos])

            register({ success = true })
            settle()
            assert.equals(1, finalized)
        end)

        it("is not sent when Codewars does not register the attempt", function()
            local k = kata()
            local register = passed_attempt(k)
            submit(k)

            register(nil, { msg = "boom" })
            settle()
            assert.equals(0, finalized)
            assert.truthy((warnings[#warnings] or ""):find("not sent", 1, true), vim.inspect(warnings))
        end)

        it("waits for every registration still in flight", function()
            local k = kata()
            local first = passed_attempt(k)
            local second = passed_attempt(k)
            assert.equals(2, k._notify_pending)
            submit(k)

            first({ success = true })
            settle()
            assert.equals(0, finalized, "submitted with a registration still in flight")
            -- handle() would re-queue an early release safely, but the user
            -- would read "Waiting for Codewars" twice for one command.
            local waiting = vim.tbl_filter(function(m) return m:find("Waiting for Codewars", 1, true) end, infos)
            assert.equals(1, #waiting, vim.inspect(infos))

            second({ success = true })
            settle()
            assert.equals(1, finalized)
        end)

        it("is sent once however many times it was asked for", function()
            local k = kata()
            local register = passed_attempt(k)
            submit(k)
            submit(k)

            register({ success = true })
            settle()
            assert.equals(1, finalized)
        end)

        -- Every notify reply passes through the release check, a quick test's
        -- included. A queued submit that is not cleared once sent would go
        -- again on the next one.
        it("is not sent again by a later run's registration", function()
            local k = kata()
            local register = passed_attempt(k)
            submit(k)
            register({ success = true })
            settle()
            assert.equals(1, finalized)

            Runner.running = false
            Runner:init(k):handle("test")
            pending.submit.cb({ result = { completed = true }, token = "t2" })
            pending.notify.cb({ success = true })
            settle()
            assert.equals(1, finalized, "a quick test's registration submitted again")
        end)

        it("does nothing once the registration it waited for is answered", function()
            local k = kata()
            local register = passed_attempt(k)
            register({ success = true })
            settle()
            assert.equals(0, finalized, "a registration with no submit waiting must not submit")
        end)
    end)

    it("a quick test's notify neither blocks submit nor revokes an earlier attempt", function()
        local k = kata()
        Runner:init(k):handle("attempt")
        pending.submit.cb({ result = { completed = true }, token = "t" })
        pending.notify.cb({ success = true })
        assert.is_true(k.last_attempt_success)

        Runner.running = false
        Runner:init(k):handle("test")
        pending.submit.cb({ result = { completed = false }, token = "t2" })
        assert.equals(0, k._notify_pending)
        pending.notify.cb(nil, { msg = "boom" })
        assert.is_true(k.last_attempt_success)
    end)

    it("notifies the session the run was submitted with, not the one current at reply time", function()
        local k = kata()
        Runner:init(k):handle("attempt")
        -- language switched while the run was in flight
        k.project_id, k.solution_id = "p2", "s2"
        pending.submit.cb({ result = { completed = true }, token = "t" })
        assert.equals("s1", pending.submit.solution_id)
        assert.same({ "p1", "s1" }, { pending.notify.project_id, pending.notify.solution_id })
        assert.is_false(k.last_attempt_success)
    end)
end)
