--- The close path of a REAL kumite workspace. A dirty close stashes the code
--- and the fixture, then destroys the buffers. When the stash does not land
--- (a refused id, a failed write) the buffers are the only copy left, so BOTH
--- of them must survive, not just the code one.
local Kumite = require("codewars-ui.kumite")
local kumite_stash = require("codewars.cache.kumite_stash")

local SERVER_ID = "6a63e7e085269ff93dc6332e"
local EDITED_CODE = "def f():\n    return 2"
local EDITED_FIXTURE = "Test.assert_equals(f(), 2)"

local function open(id)
    local ws = Kumite:new({
        id = id, title = "t", description = "", language = "python",
        code = "def f():\n    return 1", fixture = "Test.assert_equals(f(), 1)", ["package"] = "",
        test_framework = "cw-2", state = "draft",
    }, { state = "local_new" })
    ws:mount()
    vim.api.nvim_buf_set_lines(ws.bufnr, 0, -1, false, vim.split(EDITED_CODE, "\n"))
    vim.api.nvim_buf_set_lines(ws.fixture_split.bufnr, 0, -1, false, vim.split(EDITED_FIXTURE, "\n"))
    return ws
end

--- Close the workspace the way a dirty `:q!` does, by closing its window (the
--- WinClosed autocmd runs the unmount), and let the scheduled half of the close
--- run, where the buffers are deleted or kept. Calling _unmount() directly would
--- leave the window open, so deleting its buffer would close it and unmount a
--- second time, which a real close never does.
local function close(ws)
    vim.api.nvim_win_close(ws.winid, true)
    vim.wait(1000, function()
        return not vim.tbl_contains(_Cw_state.kumite or {}, ws)
    end)
end

--- A live buffer whose whole text is `text`, if one survived the close.
local function buffer_holding(text)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr)
            and table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") == text then
            return bufnr
        end
    end
end

local function cleanup()
    kumite_stash.delete(SERVER_ID)
    _Cw_state.kumite = {}
    vim.cmd("silent! tabonly!")
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(bufnr):find("RESCUED", 1, true) then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
    end
end

describe("closing a dirty kumite", function()
    after_each(cleanup)

    it("keeps the fixture as well as the code when the stash is refused", function()
        -- A server reply can carry any id; the stash refuses one that is not
        -- a Codewars id, so nothing is written and the buffers are all that
        -- is left.
        local ws = open("../../not-an-id")
        close(ws)
        assert.is_not_nil(buffer_holding(EDITED_CODE), "the code buffer was destroyed")
        local fixture = buffer_holding(EDITED_FIXTURE)
        assert.is_not_nil(fixture, "the fixture buffer was destroyed with no stash to restore it from")
        assert.truthy(vim.api.nvim_buf_get_name(fixture):find("RESCUED", 1, true))
    end)

    it("lets the user :write the rescued code and fixture to a real file", function()
        -- The workspace's BufWriteCmd only prints a hint and clears 'modified'.
        -- Kept on a rescued buffer it swallowed the first :write of the one
        -- remaining copy, reported nothing, and the text was closed away.
        local ws = open("../../not-an-id")
        close(ws)
        for _, text in ipairs({ EDITED_CODE, EDITED_FIXTURE }) do
            local bufnr = buffer_holding(text)
            assert.is_not_nil(bufnr, "no rescued buffer holds " .. text)
            local target = vim.fn.tempname()
            vim.api.nvim_buf_call(bufnr, function()
                vim.cmd("silent write " .. vim.fn.fnameescape(target))
            end)
            assert.are.equal(1, vim.fn.filereadable(target), ":write wrote nothing for " .. text)
            assert.are.same(vim.split(text, "\n"), vim.fn.readfile(target))
            vim.fn.delete(target)
        end
    end)

    it("keeps a fixture the user had toggled out of view", function()
        local ws = open("../../not-an-id")
        ws.fixture_split:hide()
        close(ws)
        assert.is_not_nil(buffer_holding(EDITED_FIXTURE), "the hidden fixture buffer was destroyed")
    end)

    it("stashes both and lets the buffers go when the stash lands", function()
        local ws = open(SERVER_ID)
        close(ws)
        local stashed = kumite_stash.get(SERVER_ID)
        assert.is_not_nil(stashed, "a valid id must stash")
        assert.are.equal(EDITED_CODE, stashed.code)
        assert.are.equal(EDITED_FIXTURE, stashed.fixture)
        assert.is_nil(buffer_holding(EDITED_CODE))
        assert.is_nil(buffer_holding(EDITED_FIXTURE))
    end)
end)
