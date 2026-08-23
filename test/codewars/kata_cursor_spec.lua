--- Where the cursor lands when a kata's solution buffer opens.
---
--- With no template the seeded file is just the graded signature, so line 1 is
--- as good as anywhere. With a template it is the user's own boilerplate —
--- imports and helpers they already wrote — and the code they actually came to
--- write is at the bottom.
local P = require("plenary.path")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

package.loaded["codewars.logger"] = {
    info = function() end,
    warn = function() end,
    error = function() end,
    err = function() end,
    debug = function() end,
}

--- Set before requiring anything: codewars.utils binds the config module table
--- at load time (utils.lua:1), so a later swap leaves it holding the old one.
local cfg = {
    user = { templates = { solution = {} } },
    lang = "python",
    langs = require("codewars.config.langs"),
    storage = { home = P:new(tmp) },
}
package.loaded["codewars.config"] = cfg

local Kata = require("codewars-ui.kata")

describe("Kata:create_buffer cursor", function()
    local n = 0

    local function open(starter)
        n = n + 1
        local kata = Kata:new("cursor-kata-" .. n, "python")
        kata.setup_code = starter
        kata:create_buffer()
        return kata
    end

    local function cursor(kata)
        return vim.api.nvim_win_get_cursor(kata.winid)
    end

    before_each(function()
        cfg.user = { templates = { solution = {} } }
    end)

    after_each(function()
        pcall(vim.cmd, "tabclose")
    end)

    it("lands on the last line of a seeded file", function()
        local kata = open("def f(a, b):\n    return None")
        local row, col = unpack(cursor(kata))
        assert.are.equal(2, row)
        -- Last character, not one past it: normal mode clamps the column to
        -- #line - 1, so asking for the end of the line lands here.
        assert.are.equal(#"    return None" - 1, col)
    end)

    it("lands at the end of a template, not on its first import", function()
        cfg.user = { templates = { solution = { python = "import math\n\n{{starter}}" } } }
        local kata = open("def f(a, b):\n    return None")
        assert.are.equal(4, (cursor(kata))[1])
    end)

    -- :CW template on re-wraps the open buffer. The rewrite moves the
    -- user's code and invalidates wherever the cursor was, so the open
    -- path's "don't override a claimed position" guard must NOT apply. And
    -- the target is the END OF THE STARTER, not EOF: with content after
    -- {{starter}} the buffer's last lines are the template's suffix.
    it(":CW template on moves to the starter's end, not EOF", function()
        local kata = open("def f(a, b):\n    return None")
        vim.api.nvim_win_set_cursor(kata.winid, { 1, 2 }) -- a claimed position
        cfg.user = { templates = { solution = {
            python = "import math\n\n{{starter}}\n\n# helpers\ndef helper(): pass",
        } } }
        assert.is_true(kata:retemplate("wrap"))
        local row, col = unpack(cursor(kata))
        -- Lines: 1 import, 2 blank, 3-4 starter, 5 blank, 6-7 suffix.
        assert.are.equal(4, row)
        assert.are.equal(#"    return None" - 1, col) -- normal mode clamps to #line - 1
        assert.are.equal(7, vim.api.nvim_buf_line_count(kata.bufnr))
    end)

    it(":CW template off leaves the cursor alone", function()
        cfg.user = { templates = { solution = { python = "import math\n\n{{starter}}" } } }
        local kata = open("def f(a, b):\n    return None")
        vim.api.nvim_win_set_cursor(kata.winid, { 1, 2 })
        assert.is_true(kata:retemplate("strip"))
        assert.are.same({ 1, 2 }, cursor(kata))
    end)

    it("leaves a restored column alone, not just a restored line", function()
        local group = vim.api.nvim_create_augroup("cw_cursor_col_spec", { clear = true })
        vim.api.nvim_create_autocmd("BufReadPost", {
            group = group,
            callback = function()
                pcall(vim.api.nvim_win_set_cursor, 0, { 1, 5 })
            end,
        })

        local path = P:new(tmp):joinpath("column-kata.py")
        path:write("line one\nline two\n", "w")

        local kata = Kata:new("column-kata", "python")
        kata.setup_code = ""
        kata:create_buffer()

        vim.api.nvim_del_augroup_by_id(group)
        assert.are.same({ 1, 5 }, cursor(kata))
    end)

    it("leaves a position another autocmd already restored alone", function()
        local group = vim.api.nvim_create_augroup("cw_cursor_spec", { clear = true })
        vim.api.nvim_create_autocmd("BufReadPost", {
            group = group,
            callback = function()
                pcall(vim.api.nvim_win_set_cursor, 0, { 2, 0 })
            end,
        })

        -- Written to disk first so opening it is a read, not a create.
        local path = P:new(tmp):joinpath("restored-kata.py")
        path:write("line one\nline two\nline three\n", "w")

        local kata = Kata:new("restored-kata", "python")
        kata.setup_code = ""
        kata:create_buffer()

        vim.api.nvim_del_augroup_by_id(group)
        assert.are.equal(2, (cursor(kata))[1])
    end)
end)
