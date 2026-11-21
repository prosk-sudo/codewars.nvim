describe("picker with the vim.ui.select backend", function()
    package.loaded["codewars.config"] = {
        lang = "python",
        user = { username = "" },
        langs = {
            { slug = "python", lang = "Python", ft = "py", comment = "#" },
            { slug = "go", lang = "Go", ft = "go", comment = "//" },
        },
    }
    package.loaded["codewars.logger"] = {
        info = function() end,
        warn = function() end,
        error = function() end,
        err = function() end,
        debug = function() end,
    }
    package.loaded["codewars.theme"] = { rank_hl = function() return "hl" end }
    package.loaded["codewars.cache.problemlist_utils"] = {
        collect_languages = function() return {} end,
        filter_by_language = function(items, lang)
            if not lang then return items end
            return vim.tbl_filter(function(i)
                return not i.languages or vim.tbl_contains(i.languages, lang)
            end, items)
        end,
    }
    package.loaded["codewars.icons"] = {
        get = function() return { completed = "C", rank = "R" } end,
    }

    local dropdown_calls = {}
    package.loaded["codewars.picker.dropdown"] = {
        provider = function() return "select" end,
        telescope = function() error("telescope must not be used") end,
        open = function(opts) table.insert(dropdown_calls, opts) end,
        _reset = function() end,
    }

    local mounted = {}
    package.loaded["codewars-ui.kata"] = {
        new = function(_, slug, lang)
            return { mount = function() table.insert(mounted, { slug = slug, lang = lang }) end }
        end,
    }

    local list_calls, snippet_calls = {}, {}
    local list_result
    package.loaded["codewars.api.kumite"] = {
        fetch_list = function(lang, page, cb)
            table.insert(list_calls, { lang = lang, page = page })
            cb(vim.tbl_extend("force", list_result, { current_page = page }))
        end,
        fetch_snippet = function(id) table.insert(snippet_calls, id) end,
    }

    package.loaded["codewars.picker"] = nil
    local picker = require("codewars.picker")

    local real_select = vim.ui.select
    local selects

    before_each(function()
        selects, dropdown_calls, mounted, list_calls, snippet_calls = {}, {}, {}, {}, {}
        vim.ui.select = function(items, opts, on_choice)
            table.insert(selects, { items = items, opts = opts, on_choice = on_choice })
        end
    end)

    after_each(function()
        vim.ui.select = real_select
    end)

    local function wait_selects(n)
        assert.is_true(vim.wait(500, function() return #selects >= n end), "select did not open")
        return selects[#selects]
    end

    local function find(sel, pred)
        for i, item in ipairs(sel.items) do
            if pred(item) then return item, i end
        end
    end

    local function control(sel, name)
        return (find(sel, function(i) return i._control == name end))
    end

    local items = {
        { slug = "multiply", name = "Multiply", rank_id = -8, rank_name = "8 kyu", languages = { "python", "go" } },
        { slug = "goonly", name = "Go Only", rank_id = -6, rank_name = "6 kyu", languages = { "go" } },
    }

    describe("kata list", function()
        local function open_list()
            picker._show_kata_list(items, "Select a Question", {}, { sort_key = "name" })
            return wait_selects(1)
        end

        it("lists filter controls without the separator, then kata", function()
            local sel = open_list()
            assert.is_not_nil(control(sel, "sort"))
            assert.is_not_nil(control(sel, "lang"))
            assert.is_not_nil(control(sel, "rank"))
            assert.is_not_nil(control(sel, "reset"))
            assert.is_nil(control(sel, "separator"))
            assert.truthy(sel.opts.prompt:find("Select a Question", 1, true))
        end)

        it("formats kata rows as text columns", function()
            local sel = open_list()
            local row = find(sel, function(i) return i.slug == "multiply" end)
            local text = sel.opts.format_item(row)
            assert.truthy(text:find("8 kyu", 1, true))
            assert.truthy(text:find("Multiply", 1, true))
        end)

        it("a sort control opens the sort menu, which reopens the list", function()
            local sel = open_list()
            sel.on_choice(control(sel, "sort"))
            assert.is_true(vim.wait(500, function() return #dropdown_calls == 1 end))
            assert.are.equal("Sort by", dropdown_calls[1].prompt_title)
            dropdown_calls[1].on_select(1)
            local again = wait_selects(2)
            assert.truthy(control(again, "sort").label:find("Shuffle", 1, true))
        end)

        it("reset clears the language filter so kata open in their own language", function()
            local sel = open_list()
            sel.on_choice(control(sel, "reset"))
            local again = wait_selects(2)
            again.on_choice(find(again, function(i) return i.slug == "goonly" end))
            assert.are.same({ { slug = "goonly", lang = "go" } }, mounted)
        end)

        it("picking a kata mounts it in the filtered language", function()
            -- the previous case reset the remembered filter; pick python again
            local sel = open_list()
            sel.on_choice(control(sel, "lang"))
            assert.is_true(vim.wait(500, function() return #dropdown_calls == 1 end))
            dropdown_calls[1].on_select({ lang = "python" })
            local again = wait_selects(2)
            again.on_choice(find(again, function(i) return i.slug == "multiply" end))
            assert.are.same({ { slug = "multiply", lang = "python" } }, mounted)
        end)

        it("cancel does nothing", function()
            local sel = open_list()
            sel.on_choice(nil)
            assert.are.equal(0, #mounted)
            assert.are.equal(0, #dropdown_calls)
        end)
    end)

    describe("kumite list", function()
        local entry = { id = "k1", title = "Fizz", author = "ann", language = "python" }

        before_each(function()
            list_result = { entries = { entry }, last_page = 3 }
        end)

        it("first page offers next and go-to, not prev", function()
            picker.kumite_browse()
            local sel = wait_selects(1)
            assert.is_not_nil(control(sel, "next"))
            assert.is_not_nil(control(sel, "goto"))
            assert.is_not_nil(control(sel, "lang"))
            assert.is_nil(control(sel, "prev"))
            assert.truthy(sel.opts.prompt:find("page 1/3", 1, true))
        end)

        it("next page fetches the following page", function()
            picker.kumite_browse()
            local sel = wait_selects(1)
            sel.on_choice(control(sel, "next"))
            assert.are.equal(2, list_calls[#list_calls].page)
            local again = wait_selects(2)
            assert.is_not_nil(control(again, "prev"))
        end)

        it("formats entries as text and opens the picked one", function()
            picker.kumite_browse()
            local sel = wait_selects(1)
            local row = find(sel, function(i) return i.id == "k1" end)
            local text = sel.opts.format_item(row)
            assert.truthy(text:find("Fizz", 1, true))
            assert.truthy(text:find("ann", 1, true))
            sel.on_choice(row)
            assert.are.same({ "k1" }, snippet_calls)
        end)

        it("language row opens the language menu and resets to page 1", function()
            picker.kumite_browse()
            local sel = wait_selects(1)
            sel.on_choice(control(sel, "lang"))
            assert.is_true(vim.wait(500, function() return #dropdown_calls == 1 end))
            dropdown_calls[1].on_select({ slug = "go" })
            assert.are.same({ lang = "go", page = 1 }, list_calls[#list_calls])
            -- drain the scheduled reopen before the real vim.ui.select returns
            assert.truthy(wait_selects(2).opts.prompt:find("Kumite · go", 1, true))
        end)
    end)
end)
