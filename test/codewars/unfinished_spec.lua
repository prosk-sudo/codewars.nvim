-- Kata you started and never submitted. A local solution file is a kata you
-- opened; it is unfinished when its kata is not completed in that language and
-- the file no longer holds the starter it was seeded with. A file seeded
-- before starters were recorded cannot be checked, so it is listed and says so.
local P = require("plenary.path")

describe("unfinished", function()
    local config = require("codewars.config")
    local unfinished = require("codewars.unfinished")
    local tmp, saved_storage

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved_storage = config.storage
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
    end)

    after_each(function()
        config.storage = saved_storage
        vim.fn.delete(tmp, "rf")
    end)

    --- A solution file as the kata left it, optionally last changed at `mtime`.
    local function file(name, text, mtime)
        local path = tmp .. "/" .. name
        vim.fn.writefile(vim.split(text, "\n"), path)
        if mtime then vim.loop.fs_utime(path, mtime, mtime) end
    end

    local function listed(completed)
        return vim.tbl_map(function(e) return e.file end, unfinished.list(completed or {}))
    end

    local STUB = "def f(x):\n    pass"

    it("lists a starter you have changed", function()
        unfinished.seeded("multiply.py", STUB)
        file("multiply.py", "def f(x):\n    return x * 2")
        local entries = unfinished.list({})
        assert.are.equal(1, #entries)
        assert.are.same({ key = "multiply", lang = "python", file = "multiply.py", checked = true },
            { key = entries[1].key, lang = entries[1].lang, file = entries[1].file, checked = entries[1].checked })
    end)

    -- Re-indenting or a trailing newline is not work on the kata.
    it("passes over a starter left as it was, whitespace aside", function()
        unfinished.seeded("multiply.py", STUB)
        file("multiply.py", "def f(x):\n  pass\n\n")
        assert.are.same({}, listed())
    end)

    it("passes over a kata completed in that language, by slug or by id", function()
        file("multiply.py", "solved")
        file("5264d2b162488dc400000001.py", "solved")
        assert.are.same({}, listed({
            { slug = "multiply", id = "x1", completedLanguages = { "python" } },
            { slug = "other", id = "5264d2b162488dc400000001", completedLanguages = { "python" } },
        }))
    end)

    it("keeps a kata completed only in another language", function()
        file("multiply.py", "half done")
        assert.are.same({ "multiply.py" }, listed({ { slug = "multiply", completedLanguages = { "java" } } }))
    end)

    it("lists a file with nothing on record, marked as not checked", function()
        file("multiply.py", STUB)
        local entries = unfinished.list({})
        assert.are.equal(1, #entries)
        assert.is_false(entries[1].checked)
    end)

    it("ignores files that are not solutions", function()
        unfinished.seeded("multiply.py", STUB) -- writes the record file itself
        file("multiply.py", STUB)
        file("notes.md", "# mine")
        assert.are.same({}, listed())
    end)

    it("lists the most recently changed first", function()
        file("old.py", "a", 1000)
        file("new.py", "b", 2000)
        file("mid.java", "c", 1500)
        assert.are.same({ "new.py", "mid.java", "old.py" }, listed())
    end)

    -- :CW reset seeds the kata again: what counts as untouched is the new
    -- starter, not the first one.
    it("takes a fresh seed over an earlier one", function()
        unfinished.seeded("multiply.py", "first starter")
        unfinished.seeded("multiply.py", STUB)
        file("multiply.py", STUB)
        assert.are.same({}, listed())
        file("multiply.py", "first starter")
        assert.are.same({ "multiply.py" }, listed())
    end)

    it("keeps the record it has when asked to fill in a missing one", function()
        unfinished.seeded("multiply.py", STUB)
        unfinished.seeded_if_unknown("multiply.py", "something else")
        file("multiply.py", STUB)
        assert.are.same({}, listed())
    end)

    -- :CW template on/off rewrites the buffer, and the file may be saved
    -- either way round afterwards.
    it("keeps an untouched starter untouched through a template toggle, saved or not", function()
        unfinished.seeded("multiply.py", STUB)
        unfinished.retemplated("multiply.py", STUB, "import logging\n\n" .. STUB)
        file("multiply.py", "import logging\n\n" .. STUB)
        assert.are.same({}, listed())
        file("multiply.py", STUB)
        assert.are.same({}, listed())
    end)

    it("does not count a template toggle on changed code as untouched", function()
        unfinished.seeded("multiply.py", STUB)
        local mine = "def f(x):\n    return 1"
        unfinished.retemplated("multiply.py", mine, "import logging\n\n" .. mine)
        file("multiply.py", "import logging\n\n" .. mine)
        assert.are.same({ "multiply.py" }, listed())
    end)

    it("treats an unreadable record as nothing on record", function()
        vim.fn.writefile({ "{ not json" }, tmp .. "/.seeded.json")
        file("multiply.py", STUB)
        local entries = unfinished.list({})
        assert.are.equal(1, #entries)
        assert.is_false(entries[1].checked)
    end)
end)
