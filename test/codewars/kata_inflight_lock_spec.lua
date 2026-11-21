-- Unpublish and delete are requests in flight just like save and publish, so
-- the editor has to be locked while they run. Without that, `:CW kata save`
-- was accepted during an unpublish: save() remembers the state it came from
-- (still `published`) and puts it back when its reply lands, so crossing
-- replies left the editor saying Published while the server held a draft.
local kstate = require("codewars.kata.state")
local KataEditor = require("codewars-ui.kata_editor")

local KATA_ID = "6a63e7e085269ff93dc6332e"
local LANG_ID = "6a63e7e085269ff93dc6332f"

local function workspace(published)
    local ws = KataEditor:new({
        id = KATA_ID,
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

    it("enters deleting from either resting state and reverts when it ends", function()
        assert.are.equal("deleting", kstate.step("draft", "delete"))
        assert.are.equal("deleting", kstate.step("published", "delete"))
        assert.are.equal(kstate.REVERT, kstate.step("deleting", "delete_done"))
        assert.are.equal(kstate.REVERT, kstate.step("deleting", "delete_failed"))
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
    local real_api, real_confirm, real_warn, real_info, real_error
    local calls, replies, warned, errors, prompt

    before_each(function()
        local log = require("codewars.logger")
        real_api = package.loaded["codewars.api.kata"]
        real_confirm = package.loaded["codewars-ui.popup.confirm"]
        real_warn, real_info, real_error = log.warn, log.info, log.error
        calls, replies, warned, errors, prompt = {}, {}, {}, {}, nil

        log.warn = function(msg) warned[#warned + 1] = msg end
        log.info = function() end
        log.error = function(msg) errors[#errors + 1] = msg end

        -- Each verb counts its calls and parks the reply, so a test decides
        -- when (and whether) the server answers.
        local function held(verb)
            return function(...)
                calls[verb] = (calls[verb] or 0) + 1
                local args = { ... }
                replies[verb] = args[#args]
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
    end)

    after_each(function()
        local log = require("codewars.logger")
        log.warn, log.info, log.error = real_warn, real_info, real_error
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
