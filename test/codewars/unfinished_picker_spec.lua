-- :CW unfinished: the kata you started and never submitted, newest first, so
-- you can pick one back up. What counts as unfinished is codewars.unfinished's
-- business; this is the picker over it, drawn the way the kata list is.
describe(":CW unfinished", function()
    local config = require("codewars.config")
    local picker, opened, mounted, said, entries, catalogue, completed, updates, listed_with
    local details, asked, asked_opts, provider, recent_items
    local saved = {}
    local STUBBED = {
        "codewars.picker", "codewars.picker.dropdown", "codewars.cache.completed",
        "codewars.cache.problemlist", "codewars.cache.recent", "codewars.unfinished", "codewars-ui.kata",
        "codewars.logger",
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
                    mine.bufnr = vim.api.nvim_create_buf(false, true)
                    return {
                        prompt_bufnr = mine.bufnr,
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
        details, asked, asked_opts, provider, recent_items = {}, nil, nil, "telescope", {}
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
            enrich = function(items, cb, opts)
                asked = vim.tbl_map(function(i) return i.slug end, items)
                asked_opts = opts
                for _, i in ipairs(items) do
                    details[i.slug] = { rank = { id = -5, name = "5 kyu" }, name = "Looked Up " .. i.slug }
                end
                cb(items)
            end,
        }
        package.loaded["codewars.cache.problemlist"] = { get = function() return catalogue end }
        package.loaded["codewars.cache.recent"] = { get = function() return recent_items end }
        package.loaded["codewars.unfinished"] = {
            list = function(c) listed_with = c; return entries end,
        }
        package.loaded["codewars-ui.kata"] = {
            new = function(_, key, lang, opts)
                return { mount = function() mounted = { key = key, lang = lang, file = opts and opts.file } end }
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

    -- :CW recent keeps the name and rank of every kata opened lately, and a
    -- solution file is a kata opened at some point: a good deal of what the
    -- catalogue lacks is there, with no call to Codewars.
    it("names a kata from the recent history when nothing else does", function()
        catalogue = {}
        recent_items = { { slug = "multiply", lang = "python", name = "Multiply Lately", rank = -7, opened_at = NOW } }
        entries = { entries[1] }
        picker.unfinished()
        local row = rows()[1]
        assert.are.equal("Multiply Lately", text(row[4]))
        assert.truthy(text(row[2]):find("7 kyu", 1, true), vim.inspect(row[2]))
        assert.is_nil(asked, "looked up a kata the recent history names")
    end)

    it("takes a name from the catalogue, then the kata's own record, then recent history, then cached details", function()
        entries = { entries[1] }
        local function name_shown()
            picker.unfinished()
            return text(rows()[1][4])
        end
        entries[1].name = "From Record"
        recent_items = { { slug = "multiply", lang = "python", name = "From Recent", rank = -7, opened_at = NOW } }
        details = { multiply = { rank = { id = -6, name = "6 kyu" }, name = "From Details" } }
        catalogue = { { slug = "multiply", name = "From Catalogue", rank_id = -8, rank_name = "8 kyu" } }
        assert.are.equal("From Catalogue", name_shown())
        catalogue = {}
        assert.are.equal("From Record", name_shown())
        entries[1].name = nil
        assert.are.equal("From Recent", name_shown())
        recent_items = {}
        assert.are.equal("From Details", name_shown())
    end)

    it("does not take another kata's name from the recent history", function()
        catalogue = {}
        recent_items = { { slug = "something-else", lang = "python", name = "Something Else", rank = -7, opened_at = NOW } }
        entries = { entries[1] }
        picker.unfinished()
        assert.are.equal("Multiply", text(rows()[1][4])) -- the file's own name, made readable
        assert.are.same({ "multiply" }, asked)
    end)

    -- kata_details.json written before names were kept holds a rank and tags
    -- and no name: a rank on its own no longer settles it.
    it("looks a kata up again when its cached details have a rank but no name", function()
        catalogue = {}
        details = { multiply = { rank = { id = -8, name = "8 kyu" }, tags = { "Fundamentals" } } }
        entries = { entries[1] }
        picker.unfinished()
        assert.are.same({ "multiply" }, asked)
        assert.is_true(asked_opts.names, "the cache would have kept the nameless entry")
        vim.wait(200, function() return opened.refreshed end)
        assert.are.equal("Looked Up multiply", text(rows()[1][4]))
    end)

    -- More kata than one lookup sends at once: the rest are looked up in the
    -- background for as long as the picker is open, and show as they arrive.
    describe("the lookup of names past the first batch", function()
        --- The first batch finds nothing; what comes later comes through
        --- on_progress, as completed.enrich calls it.
        local function enrich_that_finds_nothing_at_first()
            package.loaded["codewars.cache.completed"].enrich = function(_, cb, opts)
                asked_opts = opts
                cb({})
            end
        end

        it("shows a name that arrives after the picker opened, without reopening it", function()
            enrich_that_finds_nothing_at_first()
            catalogue = {}
            picker.unfinished()
            assert.is_function(asked_opts.on_progress, "the lookup has no way to tell the picker")
            vim.wait(200, function() return opened.refreshed end)
            opened.refreshed = false
            assert.are.equal("Multiply", text(rows()[1][4])) -- the file's own name, made readable

            details.multiply = { rank = { id = -3, name = "3 kyu" }, name = "Found Late" }
            asked_opts.on_progress()
            vim.wait(200, function() return opened.refreshed end)
            assert.is_true(opened.refreshed, "the open picker was not updated")
            assert.are.equal("Found Late", text(rows()[1][4]))
            assert.truthy(text(rows()[1][2]):find("3 kyu", 1, true), vim.inspect(rows()[1][2]))
        end)

        it("goes on looking while the picker is open, and stops once it is closed", function()
            enrich_that_finds_nothing_at_first()
            catalogue = {}
            picker.unfinished()
            assert.is_function(asked_opts.keep_going, "the lookup does not stop for anything")
            assert.is_true(asked_opts.keep_going())
            vim.api.nvim_buf_delete(opened.bufnr, { force = true })
            assert.is_false(asked_opts.keep_going())
        end)

        -- vim.ui.select cannot redraw what is on screen: the names are saved
        -- as they come and show the next time the list opens.
        it("keeps looking for the vim.ui.select list too until a row is chosen or it is cancelled", function()
            enrich_that_finds_nothing_at_first()
            provider = "select"
            catalogue = {}
            local real_select, shown = vim.ui.select, nil
            vim.ui.select = function(items, opts, cb) shown = { items = items, cb = cb } end
            picker.unfinished()
            vim.ui.select = real_select
            assert.is_true(asked_opts.keep_going())
            assert.has_no.errors(function() asked_opts.on_progress() end)
            vim.wait(50)
            shown.cb(nil)
            assert.is_false(asked_opts.keep_going())
        end)

        it("stops looking for the vim.ui.select list once a row is chosen", function()
            enrich_that_finds_nothing_at_first()
            provider = "select"
            catalogue = {}
            local real_select, shown = vim.ui.select, nil
            vim.ui.select = function(items, opts, cb) shown = { items = items, cb = cb } end
            picker.unfinished()
            vim.ui.select = real_select
            shown.cb(shown.items[1])
            assert.is_false(asked_opts.keep_going())
        end)
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

    -- The row is a file: a kata with an old `<id>.py` and a newer `<slug>.py`
    -- has a row for each, and the one picked is the one that opens.
    it("opens the chosen kata in that file's language, and that very file", function()
        picker.unfinished()
        opened.cfg.attach_mappings(1, function() end)
        opened.selected = opened.cfg.finder.entry_maker(opened.cfg.finder.results[2])
        opened.select()
        assert.are.same({ key = "5264d2b162488dc400000001", lang = "java", file = "5264d2b162488dc400000001.java" },
            mounted)
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
        assert.are.same({ key = "5264d2b162488dc400000001", lang = "java", file = "5264d2b162488dc400000001.java" },
            mounted)
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
