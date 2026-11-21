describe("picker.recent and the recent sort", function()
    package.loaded["codewars.config"] = {
        lang = "python",
        user = { username = "" },
        langs = require("codewars.config.langs"),
    }
    package.loaded["codewars.logger"] = {
        info = function() end, warn = function() end, error = function() end,
        err = function() end, debug = function() end,
    }
    package.loaded["codewars.theme"] = nil
    package.loaded["codewars.cache.problemlist_utils"] = {
        collect_languages = function() return {} end,
        filter_by_language = function(items) return items end,
    }
    package.loaded["codewars.icons"] = {
        get = function() return { completed = "C", recent = "R", rank = "*" } end,
    }

    local completed_items = {}
    package.loaded["codewars.cache.completed"] = {
        get = function() return completed_items, false end,
        update = function() end,
        enrich = function(items, cb) cb(items) end,
    }

    local history = {}
    package.loaded["codewars.cache.recent"] = { get = function() return history end }

    local dropdown_calls = {}
    package.loaded["codewars.picker.dropdown"] = {
        provider = function() return "select" end,
        open = function(opts) table.insert(dropdown_calls, opts) end,
        _reset = function() end,
    }

    local mounted = {}
    package.loaded["codewars-ui.kata"] = {
        new = function(_, slug, lang)
            return { mount = function() table.insert(mounted, { slug = slug, lang = lang }) end }
        end,
    }

    package.loaded["codewars.picker"] = nil
    local picker = require("codewars.picker")

    local real_select = vim.ui.select
    local selects

    before_each(function()
        dropdown_calls, mounted, selects = {}, {}, {}
        vim.ui.select = function(items, opts, cb)
            table.insert(selects, { items = items, opts = opts, cb = cb })
        end
    end)

    after_each(function()
        vim.ui.select = real_select
    end)

    describe("recent", function()
        it("opens nothing when there is no history", function()
            history = {}
            picker.recent()
            assert.are.equal(0, #dropdown_calls)
        end)

        it("lists history in order, marking completed vs in progress", function()
            local now = os.time()
            history = {
                { slug = "open-one", lang = "rust", name = "Open One", rank = -6, opened_at = now - 120 },
                { slug = "fake-binary", lang = "python", name = "Fake Binary", rank = -8, opened_at = now - 7200 },
            }
            completed_items = { { slug = "fake-binary", id = "x1" } }
            picker.recent()

            local call = dropdown_calls[1]
            assert.are.equal("Recent kata", call.prompt_title)
            assert.are.equal("open-one", call.entries[1].value.slug)
            assert.are.equal("R", call.entries[1].icon)
            assert.are.equal("C", call.entries[2].icon)
            assert.truthy(call.entries[1].label:find("6 kyu", 1, true))
            assert.truthy(call.entries[1].label:find("Open One", 1, true))
            assert.truthy(call.entries[1].label:find("rust", 1, true))
            assert.truthy(call.entries[1].label:find("2m", 1, true))
            assert.truthy(call.entries[2].label:find("2h", 1, true))
        end)

        it("labels an unranked kata as beta", function()
            history = { { slug = "b", lang = "python", opened_at = os.time() } }
            picker.recent()
            assert.truthy(dropdown_calls[1].entries[1].label:find("beta", 1, true))
        end)

        it("reopens the picked kata in its language", function()
            history = { { slug = "open-one", lang = "rust", opened_at = os.time() } }
            picker.recent()
            dropdown_calls[1].on_select(dropdown_calls[1].entries[1].value)
            assert.are.same({ { slug = "open-one", lang = "rust" } }, mounted)
        end)
    end)

    describe("recent sort", function()
        it("is offered as a sort mode", function()
            local keys = vim.tbl_map(function(m) return m.key end, picker.sort_modes)
            assert.is_true(vim.tbl_contains(keys, "recent"))
        end)

        it("orders newest first, undated items last", function()
            local sorted = picker._sort_items({
                { slug = "old", completedAt = "2026-01-01T00:00:00.000Z" },
                { slug = "nodate" },
                { slug = "new", completedAt = "2026-11-13T15:51:51.000Z" },
            }, "recent")
            assert.are.same({ "new", "old", "nodate" }, vim.tbl_map(function(i) return i.slug end, sorted))
        end)

        it(":CW completed opens with the recent sort", function()
            local real, got = picker._show_kata_list, nil
            picker._show_kata_list = function(_, _, _, initial) got = initial end
            completed_items = { { slug = "a", completedAt = "2026-01-01T00:00:00.000Z" } }
            picker.completed()
            vim.wait(500, function() return got ~= nil end)
            picker._show_kata_list = real
            assert.are.equal("recent", got and got.sort_key)
        end)
    end)
end)
