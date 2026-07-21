describe("picker focus/category helpers", function()
    -- Stub everything picker/init.lua touches at module scope
    package.loaded["codewars.config"] = {
        lang = "python",
        user = { username = "prosk" },
        langs = {
            { slug = "python", lang = "Python", ft = "py", comment = "#" },
            { slug = "javascript", lang = "JavaScript", ft = "js", comment = "//" },
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
        filter_by_language = function(items) return items end,
        random_for_lang = function() return nil end,
    }
    package.loaded["codewars.icons"] = {
        get = function()
            return {
                random = "R",
                focus = "F",
                focus_fundamentals = "B",
                focus_rank_up = "S",
                focus_practice_and_repeat = "P",
                focus_beta = "T",
            }
        end,
    }

    -- Capture dropdown.open calls instead of opening telescope
    local dropdown_calls = {}
    package.loaded["codewars.picker.dropdown"] = {
        open = function(opts) table.insert(dropdown_calls, opts) end,
        _reset = function() end,
    }

    -- pick_language must never touch the user API; stub exists only so the
    -- "never calls the user API" test has something to override.
    package.loaded["codewars.api.user"] = { get = function() end }

    package.loaded["codewars.picker"] = nil
    local picker = require("codewars.picker")

    before_each(function()
        dropdown_calls = {}
    end)

    local function last_call()
        return dropdown_calls[#dropdown_calls]
    end

    describe("focus_category", function()
        it("lists the 5 categories in site order", function()
            picker.focus_category(function() end)
            local call = last_call()
            assert.is_not_nil(call)
            assert.are.equal("Choose Today's Focus", call.prompt_title)
            assert.are.equal(5, #call.entries)
            assert.are.equal("fundamentals", call.entries[1].value)
            assert.are.equal("rank_up", call.entries[2].value)
            assert.are.equal("practice_and_repeat", call.entries[3].value)
            assert.are.equal("beta", call.entries[4].value)
            assert.are.equal("random", call.entries[5].value)
        end)

        it("carries per-category icons and descriptions", function()
            picker.focus_category(function() end)
            local call = last_call()
            assert.are.equal("B", call.entries[1].icon)
            assert.truthy(call.entries[1].label:match("Fundamentals"))
            assert.truthy(call.entries[1].label:match("foundational"))
        end)

        it("on_select yields the category key", function()
            local got
            picker.focus_category(function(key) got = key end)
            last_call().on_select("rank_up")
            assert.are.equal("rank_up", got)
        end)
    end)

    describe("pick_language", function()
        it("always lists every configured language (no trained-only filter)", function()
            picker.pick_language(function() end)
            local call = last_call()
            assert.is_not_nil(call)
            assert.are.equal(3, #call.entries)
            assert.are.equal("Python", call.entries[1].label)
            assert.are.equal("JavaScript", call.entries[2].label)
            assert.are.equal("Go", call.entries[3].label)
        end)

        it("never calls the user API", function()
            local api_called = false
            package.loaded["codewars.api.user"].get = function()
                api_called = true
            end
            picker.pick_language(function() end)
            assert.is_false(api_called)
        end)

        it("on_select yields the language slug", function()
            local got
            picker.pick_language(function(slug) got = slug end)
            local call = last_call()
            call.on_select(call.entries[1].value)
            assert.are.equal("python", got)
        end)

        it("preselects the configured default language", function()
            local config = package.loaded["codewars.config"]
            picker.pick_language(function() end)
            assert.are.equal(1, last_call().default_idx) -- config.lang = python

            config.lang = "go"
            picker.pick_language(function() end)
            assert.are.equal(3, last_call().default_idx)
            config.lang = "python"
        end)
    end)
end)
