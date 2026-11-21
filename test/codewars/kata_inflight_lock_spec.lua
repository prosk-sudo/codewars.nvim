-- Unpublish and delete are requests in flight just like save and publish, so
-- the editor has to be locked while they run. Without that, `:CW kata save`
-- was accepted during an unpublish: save() remembers the state it came from
-- (still `published`) and puts it back when its reply lands, so crossing
-- replies left the editor saying Published while the server held a draft.
local kstate = require("codewars.kata.state")
local KataEditor = require("codewars-ui.kata_editor")

local KATA_ID = "6a63e7e085269ff93dc6332e"
local LANG_ID = "6a63e7e085269ff93dc6332f"

local function workspace(published, id)
    local ws = KataEditor:new({
        id = id or KATA_ID,
        language = "python",
        published = published == true,
        languages = {
            python = { id = LANG_ID, name = "python", answer = "a = 1", setup = "", fixture = "t", example_fixture = "" },
        },
        code_challenge = { name = "My Kata", category = "algorithms", description = "d" },
        test_frameworks = { python = "cw-2" },
    })
    ws:snapshot()
    return ws
end

describe("kata.state in-flight unpublish and delete", function()
    it("locks the panes and labels the state while unpublishing and deleting", function()
        assert.is_true(kstate.is_locked("unpublishing"))
        assert.is_true(kstate.is_locked("deleting"))
        assert.are.equal("Unpublishing…", kstate.label("unpublishing"))
        assert.are.equal("Deleting…", kstate.label("deleting"))
    end)

    it("enters unpublishing from published and settles on draft", function()
        assert.are.equal("unpublishing", kstate.step("published", "unpublish"))
        assert.are.equal("draft", kstate.step("unpublishing", "unpublish_done"))
        assert.are.equal(kstate.REVERT, kstate.step("unpublishing", "unpublish_failed"))
    end)

    it("enters deleting from either resting state, and a failed delete reverts", function()
        assert.are.equal("deleting", kstate.step("draft", "delete"))
        assert.are.equal("deleting", kstate.step("published", "delete"))
        assert.are.equal(kstate.REVERT, kstate.step("deleting", "delete_failed"))
    end)

    it("ends a successful delete in a deleted state that nothing can leave", function()
        assert.are.equal("deleted", kstate.step("deleting", "delete_done"))
        assert.is_true(kstate.is_locked("deleted"))
        assert.is_false(kstate.is_editable("deleted"))
        assert.are.equal("Deleted", kstate.label("deleted"))
        for _, action in ipairs({ "edit", "validate", "save", "publish", "unpublish", "delete" }) do
            local next_state, why = kstate.step("deleted", action)
            assert.is_nil(next_state, action .. " must be blocked once the kata is deleted")
            assert.truthy(why:find("deleted", 1, true), why)
        end
    end)

    it("refuses every other action with a state-aware message", function()
        local lock_message = { unpublishing = "Unpublishing in progress", deleting = "Deleting in progress" }
        local own_action = { unpublishing = "unpublish", deleting = "delete" }
        for state, message in pairs(lock_message) do
            for _, action in ipairs({ "edit", "validate", "save", "publish", "unpublish", "delete" }) do
                local next_state, why = kstate.step(state, action)
                assert.is_nil(next_state, action .. " must be blocked while " .. state)
                assert.is_string(why)
                -- repeating the running action gets its own "Already ..." wording
                local expected = action == own_action[state] and "Already" or message
                assert.truthy(why:find(expected, 1, true), why)
            end
        end
    end)

    it("saving and publishing refuse unpublish and delete with their own lock messages", function()
        local _, why = kstate.step("saving", "unpublish")
        assert.truthy(why:find("Saving in progress", 1, true))
        _, why = kstate.step("publishing", "delete")
        assert.truthy(why:find("Publishing in progress", 1, true))
    end)
end)

describe("KataEditor while an unpublish or delete is in flight", function()
    local real_api, real_confirm, real_input, real_open, real_warn, real_info, real_error
    local calls, replies, answered, warned, errors, prompt, rename

    before_each(function()
        local log = require("codewars.logger")
        real_api = package.loaded["codewars.api.kata"]
        real_confirm = package.loaded["codewars-ui.popup.confirm"]
        real_input = vim.ui.input
        real_open = _Cw_state.kata_editors
        _Cw_state.kata_editors = {}
        real_warn, real_info, real_error = log.warn, log.info, log.error
        calls, replies, answered, warned, errors, prompt, rename = {}, {}, {}, {}, {}, nil, nil

        log.warn = function(msg) warned[#warned + 1] = msg end
        log.info = function() end
        log.error = function(msg) errors[#errors + 1] = msg end

        -- Each verb counts its calls and parks the reply, so a test decides
        -- when (and whether) the server answers.
        local function held(verb)
            return function(...)
                calls[verb] = (calls[verb] or 0) + 1
                -- publish passes a poll token after its callback, so look
                -- for the function rather than taking the last argument
                for _, arg in ipairs({ ... }) do
                    if type(arg) == "function" then
                        answered[verb] = false
                        replies[verb] = function(...)
                            answered[verb] = true
                            return arg(...)
                        end
                    end
                end
            end
        end
        package.loaded["codewars.api.kata"] = {
            save = held("save"),
            publish = held("publish"),
            unpublish = held("unpublish"),
            delete = held("delete"),
            default_version = function() return "3.11" end,
        }
        -- The prompt answers when the test says so, like a user would.
        package.loaded["codewars-ui.popup.confirm"] = {
            open = function(_, on_answer) prompt = on_answer end,
        }
        -- the rename prompt of the name-taken recovery, answered by the test
        vim.ui.input = function(_, on_input) rename = on_input end
    end)

    after_each(function()
        -- The editor records an unpublish or delete in flight per kata id for
        -- the whole process. A test that leaves one unanswered would lock the
        -- same id for every test after it, so answer whatever is still out
        -- (as a failure, the outcome with the least side effects).
        for _, verb in ipairs({ "unpublish", "delete" }) do
            if replies[verb] and not answered[verb] then
                replies[verb]({ msg = "test cleanup" })
            end
        end
        local log = require("codewars.logger")
        log.warn, log.info, log.error = real_warn, real_info, real_error
        vim.ui.input = real_input
        _Cw_state.kata_editors = real_open
        package.loaded["codewars.api.kata"] = real_api
        package.loaded["codewars-ui.popup.confirm"] = real_confirm
    end)

    describe("unpublish", function()
        it("refuses a save and a publish without calling the API", function()
            local ws = workspace(true)
            ws:unpublish()

            ws:save()
            ws:publish()

            assert.is_nil(calls.save, "save must not reach the API during an unpublish")
            assert.is_nil(calls.publish)
            assert.are.equal(2, #warned)
            assert.truthy(warned[1]:find("Unpublishing in progress", 1, true), warned[1])
            assert.truthy(warned[2]:find("Unpublishing in progress", 1, true), warned[2])
        end)

        it("lands on draft once the server confirms", function()
            local ws = workspace(true)
            ws:unpublish()
            assert.are.equal("unpublishing", ws.state)

            replies.unpublish(nil)

            assert.are.equal("draft", ws.state)
            assert.is_false(ws.model.published)
        end)

        it("cannot be left reading Published when a refused save's reply would have crossed it", function()
            local ws = workspace(true)
            ws:unpublish()
            ws:save()

            replies.unpublish(nil)
            -- a save that slipped through would answer after the unpublish
            if replies.save then
                replies.save(nil)
            end

            assert.are.equal("draft", ws.state)
        end)

        it("goes back to published when the request fails", function()
            local ws = workspace(true)
            ws:unpublish()

            replies.unpublish({ msg = "http error 500" })

            assert.are.equal("published", ws.state)
            assert.is_true(ws.model.published)
            assert.are.equal(1, #errors)
            assert.truthy(errors[1]:find("Unpublish failed", 1, true), errors[1])
        end)

        it("accepts a save again once the request has failed", function()
            local ws = workspace(true)
            ws:unpublish()
            replies.unpublish({ msg = "http error 500" })

            ws:save()

            assert.are.equal(1, calls.save)
            assert.are.equal("saving", ws.state)
        end)

        it("ignores a second unpublish instead of sending it twice", function()
            local ws = workspace(true)
            ws:unpublish()
            ws:unpublish()

            assert.are.equal(1, calls.unpublish)
            assert.are.equal("Already unpublishing.", warned[1])
        end)

        it("keeps the panes read-only while in flight and writable afterwards", function()
            local ws = workspace(true)
            local bufnr = vim.api.nvim_create_buf(false, true)
            ws.bufs = { answer = bufnr }

            ws:unpublish()
            assert.is_false(vim.bo[bufnr].modifiable)

            replies.unpublish(nil)
            assert.is_true(vim.bo[bufnr].modifiable)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("is still refused on a draft, without locking anything", function()
            local ws = workspace(false)
            ws:unpublish()

            assert.is_nil(calls.unpublish)
            assert.are.equal("draft", ws.state)
            assert.truthy(warned[1]:find("isn't published", 1, true), warned[1])
        end)
    end)

    describe("when the request ends, the other open workspaces of the kata", function()
        local OTHER_ID = "6a63e7e085269ff93dc63330"

        --- Stand-in for the workspaces mount() has registered. The first one
        --- is left out when it stands for an editor that was closed meanwhile.
        local function open(...)
            _Cw_state.kata_editors = { ... }
        end

        --- Count the times a workspace is told to close its window.
        local function count_closes(ws)
            local counter = { n = 0 }
            ws.close = function() counter.n = counter.n + 1 end
            return counter
        end

        it("learn that a successful unpublish made the kata a draft", function()
            local first = workspace(true)
            local reopened = workspace(true) -- loaded the page before the reply
            open(reopened)
            first:unpublish()

            replies.unpublish(nil)

            assert.are.equal("draft", reopened.state)
            assert.is_false(reopened.model.published)
        end)

        it("keep that draft through their next save", function()
            local first = workspace(true)
            local reopened = workspace(true)
            open(reopened)
            first:unpublish()
            replies.unpublish(nil)

            reopened:save()
            replies.save(nil)

            assert.are.equal("draft", reopened.state)
        end)

        it("include one that was open beside the sender all along", function()
            local first = workspace(true)
            local beside = workspace(true)
            open(first, beside)
            first:unpublish()

            replies.unpublish(nil)

            assert.are.equal("draft", first.state)
            assert.are.equal("draft", beside.state)
        end)

        it("are left alone when the unpublish fails", function()
            local first = workspace(true)
            local reopened = workspace(true)
            open(reopened)
            first:unpublish()

            replies.unpublish({ msg = "http error 500" })

            assert.are.equal("published", reopened.state)
            assert.is_true(reopened.model.published)
        end)

        it("are left alone when it is a different kata that changed", function()
            local first = workspace(true)
            local other = workspace(true, OTHER_ID)
            open(other)
            first:unpublish()

            replies.unpublish(nil)

            assert.are.equal("published", other.state)
            assert.is_true(other.model.published)
        end)

        it("find the kata deleted, refuse every action and close", function()
            local first = workspace(true)
            local reopened = workspace(true)
            local closes = count_closes(reopened)
            open(reopened)
            first:delete()
            prompt(true)

            replies.delete(nil)

            assert.are.equal("deleted", reopened.state)
            assert.are.equal(1, closes.n)
            reopened:save()
            reopened:publish()
            assert.is_nil(calls.save, "a deleted kata must not be saved")
            assert.is_nil(calls.publish)
            assert.truthy(warned[1]:find("deleted", 1, true), warned[1])
        end)

        it("close once, not twice, when the sender is registered too", function()
            local first = workspace(true)
            local beside = workspace(true)
            local first_closes, beside_closes = count_closes(first), count_closes(beside)
            open(first, beside)
            first:delete()
            prompt(true)

            replies.delete(nil)

            assert.are.equal("deleted", beside.state)
            assert.are.equal(1, first_closes.n)
            assert.are.equal(1, beside_closes.n)
        end)

        it("are left alone when the delete fails or a different kata is deleted", function()
            local first = workspace(true)
            local reopened = workspace(true)
            local other = workspace(true, OTHER_ID)
            open(reopened, other)
            first:delete()
            prompt(true)

            replies.delete({ msg = "http error 500" })

            assert.are.equal("published", reopened.state)
            assert.are.equal("published", other.state)
        end)

        it("do not hear about a different kata's successful delete", function()
            local first = workspace(true)
            local other = workspace(true, OTHER_ID)
            local closes = count_closes(other)
            open(other)
            first:delete()
            prompt(true)

            replies.delete(nil)

            assert.are.equal("published", other.state)
            assert.are.equal(0, closes.n)
        end)
    end)

    describe("a second workspace of the same kata", function()
        local OTHER_ID = "6a63e7e085269ff93dc63330"

        it("cannot save while the first one's unpublish is in flight", function()
            local first = workspace(true)
            -- the first editor is closed and the kata reopened; the page it
            -- loads still says published because the reply has not landed
            local second = workspace(true)
            first:unpublish()

            second:save()

            assert.is_nil(calls.save, "a save here would cross the unpublish reply")
            assert.truthy(warned[1]:find("Unpublishing in progress", 1, true), warned[1])
            assert.are.equal("published", second.state)
        end)

        it("cannot unpublish or delete either", function()
            local first = workspace(true)
            local second = workspace(true)
            first:unpublish()

            second:unpublish()
            second:delete()

            assert.are.equal(1, calls.unpublish)
            assert.is_nil(prompt, "no delete prompt while the first request is running")
            assert.are.equal(2, #warned)
        end)

        it("can save again once the first one's unpublish has been answered", function()
            local first = workspace(true)
            local second = workspace(true)
            first:unpublish()
            replies.unpublish(nil)

            second:save()

            assert.are.equal(1, calls.save)
        end)

        it("can save again once the first one's unpublish has failed", function()
            local first = workspace(true)
            local second = workspace(true)
            first:unpublish()
            replies.unpublish({ msg = "http error 500" })

            second:save()

            assert.are.equal(1, calls.save)
        end)

        it("cannot save while the first one's delete is in flight, and can after it fails", function()
            local first = workspace(true)
            local second = workspace(true)
            first:delete()
            prompt(true)

            second:save()
            assert.is_nil(calls.save)
            assert.truthy(warned[1]:find("Deleting in progress", 1, true), warned[1])

            replies.delete({ msg = "http error 500" })
            second:save()
            assert.are.equal(1, calls.save)
        end)

        it("is not held up by a request for a different kata", function()
            local first = workspace(true)
            local other = workspace(true, OTHER_ID)
            first:unpublish()

            other:save()

            assert.are.equal(1, calls.save)
        end)

        it("is not locked by a delete prompt that is still open", function()
            local first = workspace(true)
            local second = workspace(true)
            first:delete()

            second:save()

            assert.are.equal(1, calls.save)
        end)
    end)

    describe("a publish still waiting on the user", function()
        local function lock_warning()
            return warned[#warned]
        end

        it("is refused when a delete started while its confirmation was open", function()
            local ws = workspace(false)
            ws:publish()
            local confirm_publish = prompt
            ws:delete()
            prompt(true) -- the delete is confirmed, so the editor is now deleting

            confirm_publish(true)

            assert.is_nil(calls.publish, "a publish must not be sent while a delete is in flight")
            assert.are.equal("deleting", ws.state)
            assert.truthy(lock_warning():find("Deleting in progress", 1, true), lock_warning())
        end)

        it("is refused when a save started while its confirmation was open", function()
            local ws = workspace(false)
            ws:publish()
            local confirm_publish = prompt
            ws:save()

            confirm_publish(true)

            assert.is_nil(calls.publish)
            assert.are.equal("saving", ws.state)
            assert.truthy(lock_warning():find("Saving in progress", 1, true), lock_warning())
        end)

        it("is refused when a delete started while the name-taken rename prompt was open", function()
            local ws = workspace(false)
            ws:publish()
            prompt(true)
            replies.publish(nil, { msg = "name: Name is already taken" })
            assert.is_function(rename, "the rename prompt should be open")
            ws:delete()
            prompt(true)

            rename("Another name")

            assert.are.equal(1, calls.publish, "only the first publish may have been sent")
            assert.are.equal("deleting", ws.state)
            assert.truthy(lock_warning():find("Deleting in progress", 1, true), lock_warning())
        end)

        it("is refused once the kata has been deleted while the rename prompt was open", function()
            local ws = workspace(false)
            ws:publish()
            prompt(true)
            replies.publish(nil, { msg = "name: Name is already taken" })
            assert.is_function(rename, "the rename prompt should be open")
            ws:delete()
            prompt(true)
            replies.delete(nil)

            assert.has_no.errors(function() rename("Another name") end)

            assert.are.equal(1, calls.publish, "a deleted kata must not be published")
            assert.are.equal("deleted", ws.state)
            assert.truthy(lock_warning():find("deleted", 1, true), lock_warning())
        end)

        it("still goes ahead when nothing else started in the meantime", function()
            local ws = workspace(false)
            ws:publish()

            prompt(true)

            assert.are.equal(1, calls.publish)
            assert.are.equal("publishing", ws.state)
        end)
    end)

    describe("delete", function()
        it("does not lock the editor while the prompt is still open", function()
            local ws = workspace(true)
            ws:delete()

            assert.are.equal("published", ws.state)
            ws:save()
            assert.are.equal(1, calls.save, "a save is still allowed before the user confirms")
        end)

        it("stays unlocked and sends nothing when the prompt is declined", function()
            local ws = workspace(true)
            ws:delete()

            prompt(false)

            assert.are.equal("published", ws.state)
            assert.is_nil(calls.delete)
        end)

        it("locks once confirmed and refuses a save or publish without calling the API", function()
            local ws = workspace(false)
            ws:delete()
            prompt(true)
            assert.are.equal("deleting", ws.state)

            ws:save()
            ws:publish()

            assert.are.equal(1, calls.delete)
            assert.is_nil(calls.save, "save must not reach the API during a delete")
            assert.is_nil(calls.publish)
            assert.truthy(warned[1]:find("Deleting in progress", 1, true), warned[1])
            assert.truthy(warned[2]:find("Deleting in progress", 1, true), warned[2])
        end)

        it("refuses a confirmed delete when a save started while the prompt was open", function()
            local ws = workspace(true)
            ws:delete()
            ws:save()

            prompt(true)

            assert.are.equal("saving", ws.state)
            assert.is_nil(calls.delete)
            assert.truthy(warned[1]:find("Saving in progress", 1, true), warned[1])
        end)

        it("ignores a second delete instead of prompting again", function()
            local ws = workspace(false)
            ws:delete()
            prompt(true)
            prompt = nil

            ws:delete()

            assert.is_nil(prompt, "no second prompt while the first delete is running")
            assert.are.equal(1, calls.delete)
            assert.are.equal("Already deleting.", warned[1])
        end)

        it("goes back to the previous state and stays open when the request fails", function()
            local ws = workspace(true)
            local closed = false
            ws.close = function() closed = true end
            ws:delete()
            prompt(true)

            replies.delete({ msg = "http error 500" })

            assert.are.equal("published", ws.state)
            assert.is_false(closed)
            assert.truthy(errors[1]:find("Delete failed", 1, true), errors[1])
        end)

        it("closes the workspace once the server confirms", function()
            local ws = workspace(false)
            local closed = false
            ws.close = function() closed = true end
            ws:delete()
            prompt(true)

            replies.delete(nil)

            assert.is_true(closed)
        end)

        it("keeps the panes read-only while in flight and writable after a failure", function()
            local ws = workspace(false)
            local bufnr = vim.api.nvim_create_buf(false, true)
            ws.bufs = { answer = bufnr }
            ws:delete()
            prompt(true)
            assert.is_false(vim.bo[bufnr].modifiable)

            replies.delete({ msg = "http error 500" })
            assert.is_true(vim.bo[bufnr].modifiable)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)
end)
