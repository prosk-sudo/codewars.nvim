-- :CW unfinished: the kata you started and never submitted, newest first, so
-- you can pick one back up. What counts as unfinished is codewars.unfinished's
-- business; this is the picker over it, drawn the way the kata list is.
describe(":CW unfinished", function()
    local config = require("codewars.config")
    local picker, opened, mounted, said, entries, catalogue, completed, updates, listed_with
    local details, asked, provider
    local saved = {}
    local STUBBED = {
        "codewars.picker", "codewars.picker.dropdown", "codewars.cache.completed",
        "codewars.cache.problemlist", "codewars.unfinished", "codewars-ui.kata", "codewars.logger",
    }
    local NOW = os.time()
    local DAY = 86400

    --- Telescope as picker.dropdown hands it out, recording what is asked of it.
    local function fake_telescope()
        return {
            pickers = {
                new = function(topts, cfg)
                    -- Its own record: an update landing after its test has
                    -- ended must not write into the next one.
                    local mine = { topts = topts, cfg = cfg }
                    opened = mine
                    return {
                        prompt_bufnr = vim.api.nvim_create_buf(false, true),
                        find = function() mine.found = true end,
                        refresh = function(_, finder) mine.cfg.finder = finder; mine.refreshed = true end,
                    }
                end,
            },
            finders = { new_table = function(args) return args end },
            conf = { generic_sorter = function() return "SORTER" end },
            actions = {
                select_default = { replace = function(_, fn) opened.select = fn end },
                close = function() end,
            },
            action_state = { get_selected_entry = function() return opened.selected end },
            entry_display = { create = function() return function(segments) return segments end end },
            themes = { get_dropdown = function(o) return o end },
        }
    end

    before_each(function()
        for _, m in ipairs(STUBBED) do saved[m] = package.loaded[m] end
        opened, mounted, said, updates, listed_with = nil, nil, {}, 0, nil
        details, asked, provider = {}, nil, "telescope"
        completed = { { slug = "done", completedLanguages = { "python" } } }
        catalogue = {
            { slug = "multiply", id = "id-multiply", name = "Multiply", rank_id = -8, rank_name = "8 kyu" },
            { slug = "sum-them", id = "5264d2b162488dc400000001", name = "Sum Them", rank_id = -6, rank_name = "6 kyu" },
        }
        entries = {
            { key = "multiply", lang = "python", file = "multiply.py", mtime = NOW, checked = true },
            { key = "5264d2b162488dc400000001", lang = "java", file = "5264d2b162488dc400000001.java",
                mtime = NOW - DAY, checked = true },
        }

        package.loaded["codewars.logger"] = setmetatable({}, {
            __index = function(_, level)
                return function(m) said[#said + 1] = { level = level, msg = tostring(m) } end
            end,
        })
        local t = fake_telescope()
        package.loaded["codewars.picker.dropdown"] = {
            provider = function() return provider end,
            open = function() end,
            telescope = function() return t end,
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
            get_details = function() return details end,
            -- As the real one does: looks the kata up, caches what it found.
            enrich = function(items, cb)
                asked = vim.tbl_map(function(i) return i.slug end, items)
                for _, i in ipairs(items) do
                    details[i.slug] = { rank = { id = -5, name = "5 kyu" }, name = "Looked Up " .. i.slug }
                end
                cb(items)
            end,
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

    --- Every row as telescope would draw it: a list of { text, highlight }.
    local function rows()
        local finder = opened.cfg.finder
        return vim.tbl_map(function(r) return finder.entry_maker(r).display() end, finder.results)
    end

    local function text(segment)
        return type(segment) == "table" and segment[1] or segment
    end

    it("draws each kata as the kata list does: its rank, then its language and name", function()
        picker.unfinished()
        assert.is_true(opened.found, "no picker opened")
        local row = rows()[1]
        assert.truthy(text(row[2]):find("8 kyu", 1, true), vim.inspect(row))
        assert.truthy(row[2][2]:find("^codewars_rank"), "rank not in its colour: " .. vim.inspect(row[2]))
        assert.are.equal(row[2][2], row[1][2], "rank icon and rank in different colours")
        assert.are.equal("codewars_lang_python", row[3][2])
        assert.are.equal("Multiply", text(row[4]))
        assert.are.same({ "Python", "codewars_ref" }, row[5])
    end)

    it("opens in the same window as the kata list", function()
        picker.unfinished()
        assert.are.equal(100, opened.topts.layout_config.width)
    end)

    it("lists the most recently changed first, finding a kata named by its id", function()
        picker.unfinished()
        local second = rows()[2]
        assert.are.equal("Sum Them", text(second[4]))
        assert.truthy(text(second[2]):find("6 kyu", 1, true))
        assert.are.equal("Java", text(second[5]))
    end)

    it("says when you last changed it the way a person would", function()
        local ago = { 0, 1, 3, 15, 60 }
        entries = vim.tbl_map(function(days)
            return { key = "k" .. days, lang = "python", file = "k" .. days .. ".py", mtime = NOW - days * DAY, checked = true }
        end, ago)
        picker.unfinished()
        local said_when = vim.tbl_map(function(row) return text(row[6]) end, rows())
        assert.are.same({ "today", "yesterday", "3 days ago", "2 weeks ago", os.date("%Y-%m-%d", NOW - 60 * DAY) }, said_when)
    end)

    it("marks a kata it had nothing on record to check", function()
        entries[2].checked = false
        picker.unfinished()
        local r = rows()
        assert.are.equal("", text(r[1][7]))
        assert.are.same({ "not checked", "codewars_warning" }, r[2][7])
    end)

    -- The catalogue does not hold every kata: one opened by :CW train or
    -- focus may be missing from it, and is named by what it was opened with.
    it("uses the name and rank a kata was opened with when the catalogue lacks it", function()
        catalogue = {}
        entries[1].name, entries[1].rank_id = "Multiply", -8
        entries[2].name, entries[2].rank_id = "Sum Them", 2
        picker.unfinished()
        local r = rows()
        assert.are.equal("Multiply", text(r[1][4]))
        assert.truthy(text(r[1][2]):find("8 kyu", 1, true), vim.inspect(r[1][2]))
        assert.truthy(text(r[2][2]):find("2 dan", 1, true), vim.inspect(r[2][2]))
    end)

    it("shows the rank and name looked up before for a kata the catalogue lacks", function()
        catalogue = {}
        details = { multiply = { rank = { id = -8, name = "8 kyu" }, name = "Multiply" } }
        entries = { entries[1] }
        picker.unfinished()
        local row = rows()[1]
        assert.truthy(text(row[2]):find("8 kyu", 1, true), vim.inspect(row[2]))
        assert.are.equal("Multiply", text(row[4]))
        assert.is_nil(asked, "looked up a kata it already knew")
    end)

    -- Without waiting on it: the picker opens with what it knows, and fills
    -- the rest in once Codewars answers.
    it("looks up what nothing else names, filling it in while the picker is open", function()
        catalogue = {}
        picker.unfinished()
        assert.are.same({ "multiply", "5264d2b162488dc400000001" }, asked)
        vim.wait(200, function() return opened.refreshed end)
        assert.is_true(opened.refreshed, "the open picker was not updated")
        local row = rows()[1]
        assert.truthy(text(row[2]):find("5 kyu", 1, true), vim.inspect(row[2]))
        assert.are.equal("Looked Up multiply", text(row[4]))
    end)

    it("looks up nothing the catalogue or the kata's own record already names", function()
        entries[1].name, entries[1].rank_id = "Multiply", -8
        catalogue = { catalogue[2] }
        picker.unfinished()
        assert.is_nil(asked)
    end)

    it("makes the file's own name readable as a last resort", function()
        catalogue = {}
        entries[1].key = "how-old-will-i-be-in-2099"
        picker.unfinished()
        assert.are.equal("How old will i be in 2099", text(rows()[1][4]))
    end)

    it("finds a kata by its name or language as you type", function()
        picker.unfinished()
        local entry = opened.cfg.finder.entry_maker(opened.cfg.finder.results[2])
        assert.truthy(entry.ordinal:find("Sum Them", 1, true), entry.ordinal)
        assert.truthy(entry.ordinal:find("Java", 1, true), entry.ordinal)
    end)

    it("opens the chosen kata in that file's language", function()
        picker.unfinished()
        opened.cfg.attach_mappings(1, function() end)
        opened.selected = opened.cfg.finder.entry_maker(opened.cfg.finder.results[2])
        opened.select()
        assert.are.same({ key = "5264d2b162488dc400000001", lang = "java" }, mounted)
    end)

    -- Without telescope every picker goes through vim.ui.select: the same
    -- rows as plain text, as the kata list's are.
    it("opens through vim.ui.select when telescope is not the picker", function()
        provider = "select"
        local real_select, shown = vim.ui.select, nil
        vim.ui.select = function(items, opts, cb) shown = { items = items, opts = opts, cb = cb } end
        picker.unfinished()
        vim.ui.select = real_select
        assert.is_nil(opened, "opened telescope")
        assert.is_not_nil(shown, "did not use vim.ui.select")
        local first = shown.opts.format_item(shown.items[1])
        for _, part in ipairs({ "8 kyu", "Multiply", "Python", "today" }) do
            assert.truthy(first:find(part, 1, true), first)
        end
        shown.cb(shown.items[2])
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
