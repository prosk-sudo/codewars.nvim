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

    --- Open a kata with another plugin's restore-position autocmd claiming
    --- `pos` first, the way a real config does on BufReadPost.
    local function open_restored_to(pos, starter)
        local group = vim.api.nvim_create_augroup("cw_cursor_restore_spec", { clear = true })
        vim.api.nvim_create_autocmd("BufReadPost", {
            group = group,
            callback = function() pcall(vim.api.nvim_win_set_cursor, 0, pos) end,
        })
        local ok, kata = pcall(open, starter)
        vim.api.nvim_del_augroup_by_id(group)
        assert(ok, kata)
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

    -- Opening the kata takes the render() path, not wrap(), so it needs the
    -- same "end of the starter" answer. EOF is the template's own suffix.
    it("lands at the starter's end on open, not EOF", function()
        cfg.user = { templates = { solution = {
            python = "import math\n\n{{starter}}\n\n# helpers\ndef helper(): pass",
        } } }
        local kata = open("def f(a, b):\n    return None")
        -- Lines: 1 import, 2 blank, 3-4 starter, 5 blank, 6-7 suffix.
        assert.are.equal(4, (cursor(kata))[1])
        assert.are.equal(7, vim.api.nvim_buf_line_count(kata.bufnr))
    end)

    -- A restored position is normally left alone, but a long template makes
    -- "line 3 of the file" mean the middle of the user's own boilerplate.
    -- Inside the preamble it is not a claim on anything they came to write.
    it("overrides a restored position sitting in the template's preamble", function()
        cfg.user = { templates = { solution = { python = "import math\nimport sys\n\n{{starter}}" } } }
        local kata = open_restored_to({ 2, 0 }, "def f(a, b):\n    return None")

        assert.are.equal(5, (cursor(kata))[1]) -- end of the starter, not line 2
    end)

    -- ...but a position inside the starter is exactly where they left off.
    it("respects a restored position inside the starter", function()
        cfg.user = { templates = { solution = { python = "import math\nimport sys\n\n{{starter}}" } } }
        local kata = open_restored_to({ 4, 0 }, "def f(a, b):\n    return None")

        assert.are.same({ 4, 0 }, cursor(kata))
    end)

    -- The reported symptom. A kata is seeded once; every visit after that
    -- reads the file back, so a position derived from a fresh render was
    -- never available exactly when it was needed most.
    it("lands on the starter when reopening an existing kata", function()
        cfg.user = { templates = { solution = {
            python = "import math\nimport sys\nimport os\n\n{{starter}}",
        } } }

        local first = open("def f(a, b):\n    return None")
        local slug, buf = first.slug, first.bufnr
        pcall(vim.cmd, "tabclose")
        vim.api.nvim_buf_delete(buf, { force = true }) -- so BufReadPost fires again

        local group = vim.api.nvim_create_augroup("cw_cursor_reopen_spec", { clear = true })
        vim.api.nvim_create_autocmd("BufReadPost", {
            group = group,
            callback = function() pcall(vim.api.nvim_win_set_cursor, 0, { 2, 0 }) end,
        })

        local again = Kata:new(slug, "python")
        again.setup_code = "def f(a, b):\n    return None"
        again:create_buffer()
        vim.api.nvim_del_augroup_by_id(group)

        -- Lines: 1-3 imports, 4 blank, 5-6 starter.
        assert.are.equal(6, (cursor(again))[1])
    end)

    -- A template may put its own text after the starter on the SAME line.
    -- "One past the starter's end" is then a real column rather than an
    -- out-of-bounds one that normal mode clamps back, so the cursor lands on
    -- the template's punctuation instead of the code.
    it("lands on the user's last character, not the template's next one", function()
        cfg.user = { templates = { solution = {
            python = "int solve(int a, int b) {\n    return {{starter}};\n}\n",
        } } }
        local kata = open("a + b")
        local pos = cursor(kata)
        local line = vim.api.nvim_buf_get_lines(kata.bufnr, pos[1] - 1, pos[1], false)[1]

        assert.are.equal("    return a + b;", line)
        assert.are.equal("b", line:sub(pos[2] + 1, pos[2] + 1))
    end)

    -- Same argument as the preamble override, one row down: a position on the
    -- starter's own row but before it is still the template's text.
    it("overrides a restored position before the starter on its own row", function()
        cfg.user = { templates = { solution = { python = "x = " .. "{{starter}}" } } }
        local kata = open_restored_to({ 1, 2 }, "compute()")

        local pos = cursor(kata)
        local line = vim.api.nvim_buf_get_lines(kata.bufnr, 0, 1, false)[1]
        assert.are.equal("x = compute()", line)
        assert.are.equal(")", line:sub(pos[2] + 1, pos[2] + 1)) -- moved onto the code
    end)

    -- :CW reset rewrites the buffer back to the template, which moves the
    -- user's code out from under wherever they were standing.
    it(":CW reset moves to the starter, wherever the cursor was", function()
        cfg.user = { templates = { solution = {
            python = "import math\nimport sys\nimport os\n\n{{starter}}",
        } } }
        local kata = open("def f(a, b):\n    return None")
        vim.api.nvim_win_set_cursor(kata.winid, { 1, 3 }) -- parked in the preamble

        kata:reset_code()

        -- Lines: 1-3 imports, 4 blank, 5-6 starter.
        assert.are.equal(6, (cursor(kata))[1])
    end)

    -- Turning the template off left the cursor on a trailing blank line while
    -- turning it on left it on the last character of the same code, so the
    -- cursor appeared to move a line for no reason the user could see.
    it("ends on the same code with the template on as with it off", function()
        cfg.user = { templates = { solution = { python = "import math\n\n{{starter}}" } } }
        local kata = open("def f(a, b):\n    return None\n")

        assert.is_true(kata:retemplate("strip"))
        local off = cursor(kata)
        local off_line = vim.api.nvim_buf_get_lines(kata.bufnr, off[1] - 1, off[1], false)[1]

        assert.is_true(kata:retemplate("wrap"))
        local on = cursor(kata)
        local on_line = vim.api.nvim_buf_get_lines(kata.bufnr, on[1] - 1, on[1], false)[1]

        assert.are.equal("    return None", off_line)
        assert.are.equal(off_line, on_line)
        assert.are.equal(off[2], on[2])
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

    -- Stripping used to leave the cursor untouched, on the theory that the
    -- position was the user's. But it describes the TEMPLATED layout: the
    -- buffer loses its preamble underneath it and the window stays scrolled
    -- to rows that no longer exist, so the code ends up out of view.
    it(":CW template off moves to the end of what is left", function()
        cfg.user = { templates = { solution = { python = "import math\n\n{{starter}}" } } }
        local kata = open("def f(a, b):\n    return None")
        vim.api.nvim_win_set_cursor(kata.winid, { 1, 2 })
        assert.is_true(kata:retemplate("strip"))

        assert.are.equal(2, vim.api.nvim_buf_line_count(kata.bufnr))
        assert.are.equal(2, (cursor(kata))[1])
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
