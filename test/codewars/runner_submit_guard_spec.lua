-- Submit eligibility: only a full attempt, registered with Codewars, on the
-- session it was run against, may unlock :CW submit.
describe("Runner submit eligibility", function()
    local warnings = {}
    package.loaded["codewars.logger"] = {
        info = function() end, debug = function() end, err = function() end, error = function() end,
        warn = function(msg) warnings[#warnings + 1] = msg end,
    }
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
        pending = {}
        warnings = {}
        Runner.running = false
    end)

    it("a passing quick test does not unlock submit", function()
        local k = kata()
        Runner:init(k):handle("test")
        pending.submit.cb({ result = { completed = true }, token = "t" })
        assert.is_false(k.last_attempt_success)
    end)

    it("a passing attempt unlocks submit only once Codewars has registered it", function()
        local k = kata()
        Runner:init(k):handle("attempt")
        pending.submit.cb({ result = { completed = true }, token = "t" })
        assert.is_true(k.last_attempt_success)
        assert.equals(1, k._notify_pending)

        Runner.running = false
        Runner:init(k):handle("submit")
        assert.truthy(warnings[#warnings]:find("Still registering", 1, true))

        pending.notify.cb({ success = true })
        assert.equals(0, k._notify_pending)
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
