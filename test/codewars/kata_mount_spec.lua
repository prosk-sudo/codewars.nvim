--- Mounted-UI lifecycle. This layer had ZERO coverage until now, because nui
--- was absent from the test env — which is exactly how two regressions
--- shipped: switch_language and edit_meta both mutated state during an
--- in-flight save without asking the state machine, and only a real (locked)
--- buffer reveals that.
local KataEditor = require("codewars-ui.kata_editor")

local KATA_ID = "6a63e7e085269ff93dc6332e"

local function model()
    return {
        id = KATA_ID,
        language = "python",
        published = false,
        languages = {
            python = { id = "py1", name = "python", answer = "def hi(): return 1",
                setup = "# s", fixture = "py tests", example_fixture = "", ["package"] = "" },
        },
        code_challenge = { name = "My Kata", category = "algorithms", estimated_rank = "-6",
            tags_text = "", coauthors_wanted = true, description = "Do it." },
        test_frameworks = { python = "cw-2" },
        version_info = {
            python = { { id = "3.11", label = "3.11", default = true } },
            ruby = { { id = "3.0", label = "3.0", default = true } },
        },
        fixtures_locked = false,
    }
end

local ws

--- Shared teardown. plenary requires after_each inside a describe, so each
--- block calls this rather than registering a top-level hook.
local function cleanup()
    if ws then
        pcall(function() ws:close() end)
        for _, bufnr in pairs(ws.bufs or {}) do
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        ws = nil
    end
    _Cw_state.kata_editors = {}
end

describe("KataEditor:mount", function()
    after_each(cleanup)

    it("creates one live buffer per pane, with the language's filetype", function()
        ws = KataEditor:new(model()):mount()
        assert.are.equal(5, vim.tbl_count(ws.bufs))
        for _, pane in ipairs(KataEditor.PANES) do
            local bufnr = ws.bufs[pane.key]
            assert.is_true(vim.api.nvim_buf_is_valid(bufnr), pane.key .. " buffer must exist")
        end
        assert.are.equal("python", vim.bo[ws.bufs.answer].filetype)
        assert.are.equal("markdown", vim.bo[ws.bufs.description].filetype)
        assert.are.equal("def hi(): return 1", ws:pane_content("answer"))
    end)

    it("is clean on mount and dirty once a pane is edited", function()
        ws = KataEditor:new(model()):mount()
        assert.is_false(ws:is_dirty())
        vim.api.nvim_buf_set_lines(ws.bufs.answer, 0, -1, false, { "def hi(): return 2" })
        assert.is_true(ws:is_dirty())
    end)
end)

describe("in-flight save locks the workspace", function()
    after_each(cleanup)

    it("makes every pane non-modifiable while saving", function()
        ws = KataEditor:new(model()):mount()
        ws.state = "saving"
        ws:set_panes_locked(true)
        for _, pane in ipairs(KataEditor.PANES) do
            assert.is_false(vim.bo[ws.bufs[pane.key]].modifiable, pane.key .. " must be locked")
        end
    end)

    it("refuses a language switch instead of throwing mid-mutation", function()
        -- REGRESSION: switch_language rewrote locked buffers, which errors —
        -- after self.lang had already moved, leaving buffers and model
        -- disagreeing and the next save filing code under the wrong language.
        ws = KataEditor:new(model()):mount()
        ws.state = "saving"
        ws:set_panes_locked(true)

        local ok = pcall(function() ws:switch_language("ruby") end)
        assert.is_true(ok, "must not throw")
        assert.are.equal("python", ws.lang, "language must not move during a save")
        assert.is_nil(ws.model.languages.ruby, "no language may be added during a save")
    end)

    it("refuses a metadata edit instead of having it silently reverted", function()
        -- REGRESSION: adopt() installs the payload that was already sent, so
        -- metadata typed mid-save was overwritten with no warning.
        ws = KataEditor:new(model()):mount()
        ws.state = "saving"
        local before = ws.cc.name
        ws:edit_meta()
        assert.are.equal(before, ws.cc.name)
    end)

    it("allows both again once the save finishes", function()
        ws = KataEditor:new(model()):mount()
        ws.state = "saving"
        ws:set_panes_locked(true)
        ws.state = "draft"
        ws:set_panes_locked(false)
        ws:switch_language("ruby")
        assert.are.equal("ruby", ws.lang)
    end)
end)

describe("closing with unsaved work", function()
    after_each(cleanup)

    it("stashes the live description, not the stale copy", function()
        -- REGRESSION: the stash stored deepcopy(self.cc), whose description is
        -- only refreshed inside build_model() — so a SUCCESSFUL stash restored
        -- the old description.
        ws = KataEditor:new(model()):mount()
        vim.api.nvim_buf_set_lines(ws.bufs.description, 0, -1, false, { "EDITED description" })

        local captured
        package.loaded["codewars.cache.kata_stash"] = {
            save = function(entry) captured = entry return "/tmp/kata-stash-x.json" end,
        }
        ws:_unmount()
        package.loaded["codewars.cache.kata_stash"] = nil

        assert.is_not_nil(captured, "a dirty close must stash")
        assert.are.equal("EDITED description", captured.code_challenge.description)
    end)
end)
