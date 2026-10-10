-- :CW next opens the first unsolved kata the list would show, without the
-- picker. `focus` is Codewars' curated queue; this is your own slice of the
-- catalogue, read from the filters you last chose in the list menus.
describe(":CW next", function()
    local cmd, config, utils
    local mounted, said, filters, completed, items
    local real_picker, real_problemlist, real_kata, real_logger, real_guard

    before_each(function()
        mounted, said = {}, {}
        items = {
            { slug = "a8", rank_id = -8, languages = { "python" } },
            { slug = "b8", rank_id = -8, languages = { "python" } },
            { slug = "c6", rank_id = -6, languages = { "python", "rust" } },
            { slug = "d7", rank_id = -7, languages = { "rust" } },
        }
        completed = {}
        filters = { lang = "python", rank = nil, sort = "easiest" }

        real_picker = package.loaded["codewars.picker"]
        real_problemlist = package.loaded["codewars.cache.problemlist"]
        real_kata = package.loaded["codewars-ui.kata"]
        real_logger = package.loaded["codewars.logger"]

        package.loaded["codewars.picker"] = {
            current_filters = function() return vim.deepcopy(filters) end,
            with_completed = function(cb) cb(completed) end,
        }
        package.loaded["codewars.cache.problemlist"] = {
            get = function() return items end,
            refresh_if_stale = function() end,
        }
        package.loaded["codewars-ui.kata"] = {
            new = function(_, slug, lang)
                return { mount = function() table.insert(mounted, { slug = slug, lang = lang }) end }
            end,
        }
        package.loaded["codewars.logger"] = setmetatable({}, {
            __index = function(_, level)
                return function(m) table.insert(said, { level = level, msg = tostring(m) }) end
            end,
        })

        package.loaded["codewars.command"] = nil
        cmd = require("codewars.command")
        config = require("codewars.config")
        utils = require("codewars.utils")
        real_guard = utils.auth_guard
        utils.auth_guard = function() end
        config.lang = "python"
    end)

    after_each(function()
        utils.auth_guard = real_guard
        package.loaded["codewars.picker"] = real_picker
        package.loaded["codewars.cache.problemlist"] = real_problemlist
        package.loaded["codewars-ui.kata"] = real_kata
        package.loaded["codewars.logger"] = real_logger
        package.loaded["codewars.command"] = nil
    end)

    local function last_said(level)
        for i = #said, 1, -1 do
            if said[i].level == level then return said[i].msg end
        end
    end

    it("opens the first kata the list would show, in the list's language", function()
        cmd.next({})
        assert.are.same({ { slug = "a8", lang = "python" } }, mounted)
    end)

    it("skips what you have already solved", function()
        completed = { a8 = true }
        cmd.next({})
        assert.are.equal("b8", mounted[1].slug)
    end)

    it("uses the rank you last chose in the list menu", function()
        filters.rank = -6
        cmd.next({})
        assert.are.equal("c6", mounted[1].slug)
    end)

    it("takes a kyu on the command line, for this call only", function()
        cmd.next({ _positional = { "6" } })
        assert.are.equal("c6", mounted[1].slug)
    end)

    it("takes a language on the command line", function()
        -- Easiest-first, and rank ids are negative: d7 (-7) comes before c6 (-6).
        cmd.next({ _positional = { "rust" } })
        assert.are.same({ slug = "d7", lang = "rust" }, mounted[1])
    end)

    it("takes both, in either order", function()
        cmd.next({ _positional = { "rust", "7" } })
        assert.are.same({ slug = "d7", lang = "rust" }, mounted[1])
        cmd.next({ _positional = { "7", "rust" } })
        assert.are.same({ slug = "d7", lang = "rust" }, mounted[2])
    end)

    it("accepts a list of kyu like the list command does", function()
        completed = { a8 = true, b8 = true }
        cmd.next({ _positional = { "8,6" } })
        assert.are.equal("c6", mounted[1].slug)
    end)

    it("rejects a kyu outside 1-8 and an unknown language, opening nothing", function()
        cmd.next({ _positional = { "9" } })
        cmd.next({ _positional = { "klingon" } })
        assert.are.same({}, mounted)
        assert.is_not_nil(last_said("error"))
    end)

    it("says so when nothing unsolved is left, naming the slice", function()
        completed = { a8 = true, b8 = true, c6 = true }
        cmd.next({})
        assert.are.same({}, mounted)
        local m = last_said("info")
        assert.truthy(m and m:find("python", 1, true), m)
        assert.truthy(m and m:find(":CW list", 1, true), m)
    end)

    it("points at the cache when the problem list is empty", function()
        items = {}
        cmd.next({})
        assert.are.same({}, mounted)
        assert.truthy((last_said("warn") or ""):find("cache update", 1, true))
    end)

    it("is listed in :CW help under training", function()
        local text = table.concat((cmd._help_lines()), "\n")
        assert.truthy(text:find(":CW next", 1, true), "next is not in the help")
    end)
end)
