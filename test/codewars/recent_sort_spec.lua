-- "Recently completed": :CW completed opens newest first. Only a list whose
-- kata carry a completion date can be sorted by it, so only that list offers
-- it, and it is never remembered for :CW list or :CW next.
describe("the recently completed sort", function()
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

    local dropdown_calls = {}
    package.loaded["codewars.picker.dropdown"] = {
        provider = function() return "select" end,
        open = function(opts) table.insert(dropdown_calls, opts) end,
        _reset = function() end,
    }

    package.loaded["codewars.picker"] = nil
    local picker = require("codewars.picker")

    local real_select = vim.ui.select
    local selects

    before_each(function()
        dropdown_calls, selects = {}, {}
        vim.ui.select = function(items, opts, cb)
            table.insert(selects, { items = items, opts = opts, cb = cb })
        end
    end)

    after_each(function()
        vim.ui.select = real_select
    end)

    local catalogue = {
        { slug = "a", name = "A", rank_id = -8 },
        { slug = "b", name = "B", rank_id = -6 },
    }
    local solved = {
        { slug = "a", name = "A", rank = { id = -8 }, completedAt = "2026-01-01T00:00:00.000Z" },
        { slug = "b", name = "B", rank = { id = -6 }, completedAt = "2026-11-13T15:51:51.000Z" },
    }

    --- The Sort menu of a list showing `items`, opened from its Sort row.
    local function sort_menu_for(items)
        picker._show_kata_list(items, "Select a Question", {}, {})
        local list = selects[#selects]
        for _, choice in ipairs(list.items) do
            if choice._control == "sort" then list.cb(choice) end
        end
        vim.wait(200, function() return #dropdown_calls > 0 end)
        return dropdown_calls[#dropdown_calls]
    end

    local function entry(menu, label)
        for _, e in ipairs(menu.entries) do
            if e.label:find(label, 1, true) then return e end
        end
    end

    it("orders newest first, undated items last", function()
        local sorted = picker._sort_items({
            { slug = "old", completedAt = "2026-01-01T00:00:00.000Z" },
            { slug = "nodate" },
            { slug = "new", completedAt = "2026-11-13T15:51:51.000Z" },
        }, "recent")
        assert.are.same({ "new", "old", "nodate" }, vim.tbl_map(function(i) return i.slug end, sorted))
    end)

    it("is what :CW completed opens with", function()
        local real, got = picker._show_kata_list, nil
        picker._show_kata_list = function(_, _, _, initial) got = initial end
        completed_items = { { slug = "a", completedAt = "2026-01-01T00:00:00.000Z" } }
        picker.completed()
        vim.wait(500, function() return got ~= nil end)
        picker._show_kata_list = real
        assert.are.equal("recent", got and got.sort_key)
    end)

    it("is offered in the completed list", function()
        assert.is_not_nil(entry(sort_menu_for(solved), "Recently completed"))
    end)

    it("is not offered in the kata list, whose kata have no completion date", function()
        local menu = sort_menu_for(catalogue)
        assert.is_not_nil(entry(menu, "Name (A-Z)"), "the other sorts went missing")
        assert.is_nil(entry(menu, "Recently completed"))
    end)

    --- Choose `label` in a Sort menu and wait for the scheduled list reopen to
    --- hit the stubbed vim.ui.select. Left pending, it fires after the last
    --- after_each restores the real one, blocks on a prompt, and plenary's
    --- timeout kills the spec process (suite exits 1 with every test green).
    local function choose_sort(menu, label)
        local before = #selects
        menu.on_select(entry(menu, label).value)
        vim.wait(200, function() return #selects > before end)
        assert.is_true(#selects > before, "choosing a sort did not reopen the list")
    end

    it("is never remembered for :CW list or :CW next", function()
        choose_sort(sort_menu_for(solved), "Name (A-Z)")
        assert.are.equal("name", picker.current_filters().sort)

        choose_sort(sort_menu_for(solved), "Recently completed")
        assert.are.equal("name", picker.current_filters().sort)
    end)
end)
