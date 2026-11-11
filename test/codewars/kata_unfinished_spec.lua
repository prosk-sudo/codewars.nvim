--- What a kata puts on record so :CW unfinished can tell a kata you are in the
--- middle of from one you only opened: the starter it seeds, a re-seed on
--- :CW reset, and a template toggle that rewrites an untouched starter.
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

local cfg = {
    user = { templates = { solution = {} }, indent = {} },
    lang = "python",
    langs = require("codewars.config.langs"),
    storage = { home = P:new(tmp), cache = P:new(tmp) },
}
package.loaded["codewars.config"] = cfg

local Kata = require("codewars-ui.kata")
local templates = require("codewars.templates")
local unfinished = require("codewars.unfinished")

describe("Kata and :CW unfinished", function()
    local STUB = "def f(x):\n    pass"
    local n = 0

    --- Open a kata seeded with `starter`; `on_disk` pre-creates its file, the
    --- way a kata visited before starters were recorded looks.
    local function open(starter, on_disk)
        n = n + 1
        local slug = "unfinished-kata-" .. n
        if on_disk then
            cfg.storage.home:joinpath(slug .. ".py"):write(on_disk, "w")
        end
        local kata = Kata:new(slug, "python")
        kata.setup_code = starter
        kata:create_buffer()
        return kata, slug .. ".py"
    end

    local function listed(file)
        for _, e in ipairs(unfinished.list({})) do
            if e.file == file then return e end
        end
    end

    local function save(kata)
        vim.api.nvim_buf_call(kata.bufnr, function() vim.cmd("silent write") end)
    end

    before_each(function()
        templates.set_enabled(true)
        cfg.user = { templates = { solution = {} }, indent = {} }
    end)

    after_each(function()
        pcall(vim.cmd, "silent! tabclose!")
    end)

    it("keeps a new kata off the list until its code changes", function()
        local kata, file = open(STUB)
        assert.is_nil(listed(file), "an untouched starter was listed")

        vim.api.nvim_buf_set_lines(kata.bufnr, 0, -1, false, { "def f(x):", "    return x" })
        save(kata)
        local entry = listed(file)
        assert.is_not_nil(entry, "changed code was not listed")
        assert.is_true(entry.checked)
    end)

    it("records the kata's name and rank when it opens the file", function()
        n = n + 1
        local slug = "unfinished-kata-" .. n
        local kata = Kata:new(slug, "python")
        kata.setup_code, kata.name, kata.rank = STUB, "Multiply", -8
        kata:create_buffer()
        vim.api.nvim_buf_set_lines(kata.bufnr, 0, -1, false, { "def f(x):", "    return x" })
        save(kata)

        local entry = listed(slug .. ".py")
        assert.are.equal("Multiply", entry.name)
        assert.are.equal(-8, entry.rank_id)
    end)

    -- A file from before starters were recorded: opening it is the first
    -- chance to check it.
    it("checks a file with nothing on record against the starter when opened", function()
        local _, untouched = open(STUB, STUB .. "\n")
        assert.is_nil(listed(untouched))

        local _, changed = open(STUB, "def f(x):\n    return 2\n")
        local entry = listed(changed)
        assert.is_not_nil(entry)
        assert.is_true(entry.checked)
    end)

    -- Codewars can change a starter between visits, and so can the indent
    -- option; after a reset, the new one is what counts as untouched.
    it("counts a reset as a fresh start", function()
        local kata, file = open(STUB)
        kata.setup_code = "def f(x, y):\n    pass"
        kata:reset_code()
        save(kata)
        assert.is_nil(listed(file), "a just-reset kata was listed")
    end)

    -- Older versions named a kata opened by its id after the id. The kata now
    -- resolves to its slug before the file is opened, so without this the
    -- work in that file never showed: a fresh starter was seeded beside it.
    it("opens a file named after the kata's id when there is none by its slug", function()
        n = n + 1
        local slug, id = "unfinished-kata-" .. n, ("%024x"):format(n)
        local mine = "def f(x):\n    return 'mine'"
        cfg.storage.home:joinpath(id .. ".py"):write(mine, "w")

        local kata = Kata:new(slug, "python")
        kata.kata_id = id
        kata.setup_code = STUB
        kata:create_buffer()

        assert.are.equal(mine, table.concat(vim.api.nvim_buf_get_lines(kata.bufnr, 0, -1, false), "\n"))
        assert.is_false(cfg.storage.home:joinpath(slug .. ".py"):exists(), "seeded a second file beside it")
    end)

    it("keeps an untouched kata off the list through a template toggle", function()
        cfg.user.templates = { solution = { python = "import logging\n\n{{starter}}" } }
        templates.set_enabled(false)
        local kata, file = open(STUB)
        templates.set_enabled(true)
        assert.is_true(kata:retemplate("wrap"))
        save(kata)
        assert.is_nil(listed(file), "a template toggle made an untouched kata look started")
    end)
end)
