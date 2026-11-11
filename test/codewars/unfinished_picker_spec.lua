-- :CW unfinished: the kata you started and never submitted, newest first, so
-- you can pick one back up. What counts as unfinished is codewars.unfinished's
-- business; this is the picker over it.
describe(":CW unfinished", function()
    local config = require("codewars.config")
    local picker, opened, mounted, said, entries, catalogue, completed, updates, listed_with
    local saved = {}
    local STUBBED = {
        "codewars.picker", "codewars.picker.dropdown", "codewars.cache.completed",
        "codewars.cache.problemlist", "codewars.unfinished", "codewars-ui.kata", "codewars.logger",
    }

    local DAY = os.time({ year = 2026, month = 11, day = 10, hour = 12 })

    before_each(function()
        for _, m in ipairs(STUBBED) do saved[m] = package.loaded[m] end
        opened, mounted, said, updates, listed_with = nil, nil, {}, 0, nil
        completed = { { slug = "done", completedLanguages = { "python" } } }
        catalogue = {
            { slug = "multiply", id = "id-multiply", name = "Multiply" },
            { slug = "sum-them", id = "5264d2b162488dc400000001", name = "Sum Them" },
        }
        entries = {
            { key = "multiply", lang = "python", file = "multiply.py", mtime = DAY, checked = true },
            { key = "5264d2b162488dc400000001", lang = "java", file = "5264d2b162488dc400000001.java",
                mtime = DAY - 86400, checked = true },
        }

        package.loaded["codewars.logger"] = setmetatable({}, {
            __index = function(_, level)
                return function(m) said[#said + 1] = { level = level, msg = tostring(m) } end
            end,
        })
        package.loaded["codewars.picker.dropdown"] = {
            open = function(opts) opened = opts end,
            telescope = function() end,
            _reset = function() end,
        }
        package.loaded["codewars.cache.completed"] = {
            get = function() return completed, false end,
            update = function(cb)
                updates = updates + 1
                completed = { { slug = "fetched", completedLanguages = { "python" } } }
                cb(completed)
            end,
            mark = function() end,
            enrich = function(d, cb) cb(d) end,
        }
        package.loaded["codewars.cache.problemlist"] = { get = function() return catalogue end }
        package.loaded["codewars.unfinished"] = {
            list = function(c) listed_with = c; return entries end,
        }
        package.loaded["codewars-ui.kata"] = {
            new = function(_, key, lang)
                return { mount = function() mounted = { key = key, lang = lang } end }
            end,
        }
        package.loaded["codewars.picker"] = nil
        picker = require("codewars.picker")
    end)

    after_each(function()
        for _, m in ipairs(STUBBED) do package.loaded[m] = saved[m] end
    end)

    local function labels()
        return vim.tbl_map(function(e) return e.label end, opened.entries)
    end

    it("lists each kata by name, newest first, with its language and when it last changed", function()
        picker.unfinished()
        assert.is_not_nil(opened, "no picker opened")
        local l = labels()
        assert.are.equal(2, #l)
        assert.truthy(l[1]:find("Multiply", 1, true), l[1])
        assert.truthy(l[1]:find("python", 1, true), l[1])
        assert.truthy(l[1]:find("2026-11-10", 1, true), l[1])
        -- Named by id on disk, found by id in the catalogue.
        assert.truthy(l[2]:find("Sum Them", 1, true), l[2])
        assert.truthy(l[2]:find("java", 1, true), l[2])
    end)

    it("falls back to the file's own name for a kata the catalogue does not have", function()
        catalogue = {}
        picker.unfinished()
        assert.truthy(labels()[1]:find("multiply", 1, true), labels()[1])
    end)

    it("marks a kata it had nothing on record to check", function()
        entries[2].checked = false
        picker.unfinished()
        assert.is_nil(labels()[1]:find("not checked", 1, true), labels()[1])
        assert.truthy(labels()[2]:find("not checked", 1, true), labels()[2])
    end)

    it("opens the chosen kata in that file's language", function()
        picker.unfinished()
        opened.on_select(opened.entries[2].value)
        assert.are.same({ key = "5264d2b162488dc400000001", lang = "java" }, mounted)
    end)

    it("leaves out what you completed, judged on your completed list", function()
        picker.unfinished()
        assert.are.same(completed, listed_with)
    end)

    it("fetches your completed list first when there is none yet", function()
        local saved_user = config.user.username
        config.user.username = "me"
        completed = {}
        picker.unfinished()
        vim.wait(100, function() return opened ~= nil end)
        config.user.username = saved_user
        assert.are.equal(1, updates)
        assert.are.equal("fetched", listed_with[1].slug)
    end)

    it("says so when nothing is unfinished, and opens no picker", function()
        entries = {}
        picker.unfinished()
        assert.is_nil(opened)
        local msg = said[#said] and said[#said].msg or ""
        assert.truthy(msg:find("unfinished", 1, true), msg)
    end)

    it("is a :CW subcommand listed in :CW help", function()
        package.loaded["codewars.command"] = nil
        local cmd = require("codewars.command")
        assert.are.equal(cmd.unfinished, cmd.commands.unfinished[1])
        local found = false
        for _, row in ipairs(cmd._help_lines()) do
            if vim.inspect(row):find("unfinished", 1, true) then found = true end
        end
        package.loaded["codewars.command"] = nil
        assert.is_true(found, "not in :CW help")
    end)
end)
