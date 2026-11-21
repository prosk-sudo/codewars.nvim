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

    -- Indentation, trailing spaces, blank lines and the final newline are not
    -- work on the kata. Anything else is, down to one space inside a string.
    it("tells a changed space inside a string literal from the starter", function()
        unfinished.seeded("greet.py", 'def f():\n    return "hello world"')
        file("greet.py", 'def f():\n    return "helloworld"')
        assert.are.same({ "greet.py" }, listed())
    end)

    it("tells two spaces from one inside a string literal, either way round", function()
        unfinished.seeded("greet.py", 'def f():\n    return "hello  world"')
        file("greet.py", 'def f():\n    return "hello world"')
        assert.are.same({ "greet.py" }, listed())
        unfinished.seeded("greet.py", 'def f():\n    return "hello world"')
        file("greet.py", 'def f():\n    return "hello  world"')
        assert.are.same({ "greet.py" }, listed())
    end)

    it("tells whitespace between tokens from the starter", function()
        unfinished.seeded("multiply.py", "def f(x):\n    y = x + 1")
        for _, changed in ipairs({ "y = x+1", "y  =  x + 1", "y = x\t+ 1" }) do
            file("multiply.py", "def f(x):\n    " .. changed)
            assert.are.same({ "multiply.py" }, listed(), changed)
        end
    end)

    it("passes over a starter whose indentation, trailing spaces, blank lines and final newline changed", function()
        unfinished.seeded("multiply.py", "def f(x):\n    y = x + 1\n    return y")
        file("multiply.py", "def f(x):\n\n\t y = x + 1  \n\n  return y\n\n")
        assert.are.same({}, listed())
        file("multiply.py", "def f(x):\r\n  y = x + 1\r\n  return y\r\n")
        assert.are.same({}, listed())
    end)

    -- Records already on disk were made by the old fingerprint, which ignored
    -- every space; new ones say which they are.
    it("marks the fingerprints it writes with a version", function()
        unfinished.seeded("multiply.py", STUB)
        local record = vim.json.decode(table.concat(vim.fn.readfile(tmp .. "/.seeded.json"), "\n"))
        assert.truthy(record["multiply.py"].prints[1]:find("^v2:"), vim.inspect(record))
    end)

    --- A record as an earlier version wrote it: a bare sha256 of the text with
    --- every whitespace character removed.
    local function legacy_record(name, starter)
        local fp = vim.fn.sha256((starter:gsub("%s+", "")))
        vim.fn.writefile({ vim.json.encode({ [name] = { prints = { fp } } }) }, tmp .. "/.seeded.json")
    end

    it("still reads a starter recorded by the old fingerprint, as that one did", function()
        legacy_record("multiply.py", STUB)
        file("multiply.py", "def f(x):\n  pass\n")
        assert.are.same({}, listed(), "an old record made every seeded file look edited")
        file("multiply.py", "def f(x):\n    return 1")
        assert.are.same({ "multiply.py" }, listed())
    end)

    it("keeps an old record's starter through a template toggle, beside the new one", function()
        legacy_record("multiply.py", STUB)
        unfinished.retemplated("multiply.py", STUB, "import logging\n\n" .. STUB)
        file("multiply.py", "import logging\n\n" .. STUB)
        assert.are.same({}, listed())
        file("multiply.py", STUB)
        assert.are.same({}, listed())
        file("multiply.py", "import logging\n\n" .. STUB .. "\n    return 1")
        assert.are.same({ "multiply.py" }, listed())
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

    -- Two saves in the same second are still two moments: the order is the
    -- full modification time, and only a tie on that goes by file name.
    it("orders files saved within the same second by the fraction of it", function()
        file("a-older.py", "a", 1000.25)
        local stat = vim.loop.fs_stat(tmp .. "/a-older.py")
        if stat.mtime.nsec == 0 then return pending("this filesystem keeps whole seconds only") end
        file("z-newer.py", "z", 1000.75)
        file("m-newer-too.py", "m", 1000.75)
        assert.are.same({ "m-newer-too.py", "z-newer.py", "a-older.py" }, listed())
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

    -- :CW reset puts a new starter in the buffer, but the file on disk only
    -- changes when it is saved: until then the old starter is what the list
    -- reads, so it has to stay on record beside the new one.
    describe("reseeded", function()
        it("adds the new starter to the ones on record", function()
            unfinished.seeded("multiply.py", "first starter")
            unfinished.reseeded("multiply.py", STUB)
            file("multiply.py", "first starter")
            assert.are.same({}, listed(), "the old starter, still on disk, was listed")
            file("multiply.py", STUB)
            assert.are.same({}, listed())
            file("multiply.py", "def f(x):\n    return 1")
            assert.are.same({ "multiply.py" }, listed())
        end)

        it("starts the record with the new starter when nothing is on record", function()
            unfinished.reseeded("multiply.py", STUB)
            file("multiply.py", STUB)
            assert.are.same({}, listed())
            file("multiply.py", "def f(x):\n    return 1")
            local entries = unfinished.list({})
            assert.are.equal(1, #entries)
            assert.is_true(entries[1].checked)
        end)

        it("does not add a starter that is already on record", function()
            unfinished.seeded("multiply.py", STUB)
            unfinished.reseeded("multiply.py", STUB)
            unfinished.reseeded("multiply.py", "def f(x):\n        pass")
            local record = vim.json.decode(table.concat(vim.fn.readfile(tmp .. "/.seeded.json"), "\n"))
            assert.are.equal(1, #record["multiply.py"].prints, vim.inspect(record))
        end)

        it("keeps the name and rank, and takes new ones", function()
            unfinished.seeded("multiply.py", STUB, { name = "Multiply", rank_id = -8 })
            unfinished.reseeded("multiply.py", "def f(x, y):\n    pass")
            file("multiply.py", "changed")
            assert.are.equal("Multiply", unfinished.list({})[1].name)
            unfinished.reseeded("multiply.py", STUB, { name = "Multiply (renamed)", rank_id = -7 })
            local entry = unfinished.list({})[1]
            assert.are.equal("Multiply (renamed)", entry.name)
            assert.are.equal(-7, entry.rank_id)
        end)

        it("keeps a starter an earlier version recorded", function()
            legacy_record("multiply.py", STUB)
            unfinished.reseeded("multiply.py", "def f(x, y):\n    pass")
            file("multiply.py", "def f(x):\n  pass")
            assert.are.same({}, listed())
        end)
    end)

    it("keeps the starter it has on record when an opened file already has one", function()
        unfinished.seeded("multiply.py", STUB)
        unfinished.opened("multiply.py", "something else")
        file("multiply.py", STUB)
        assert.are.same({}, listed())
    end)

    it("only makes the starter when there is none on record", function()
        unfinished.seeded("multiply.py", STUB)
        local made = false
        unfinished.opened("multiply.py", function() made = true; return "x" end)
        assert.is_false(made)
    end)

    -- The catalogue does not hold every kata, so the picker would otherwise
    -- have nothing but a file name to show for one opened by :CW train.
    it("remembers the name and rank the kata was opened with", function()
        unfinished.seeded("multiply.py", STUB, { name = "Multiply", rank_id = -8 })
        file("multiply.py", "def f(x):\n    return x * 2")
        local entry = unfinished.list({})[1]
        assert.are.equal("Multiply", entry.name)
        assert.are.equal(-8, entry.rank_id)

        unfinished.opened("multiply.py", STUB, { name = "Multiply (renamed)", rank_id = -7 })
        entry = unfinished.list({})[1]
        assert.are.equal("Multiply (renamed)", entry.name)
        assert.are.equal(-7, entry.rank_id)
    end)

    it("keeps the name and rank through a reset that does not repeat them", function()
        unfinished.seeded("multiply.py", STUB, { name = "Multiply", rank_id = -8 })
        unfinished.seeded("multiply.py", "def f(x, y):\n    pass")
        file("multiply.py", "changed")
        assert.are.equal("Multiply", unfinished.list({})[1].name)
    end)

    it("reads a record written as a bare list of starters", function()
        vim.fn.writefile({ vim.json.encode({ ["multiply.py"] = { unfinished.fingerprint(STUB) } }) }, tmp .. "/.seeded.json")
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
