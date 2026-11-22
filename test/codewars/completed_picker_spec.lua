-- :CW completed shows its enriched list only for the account it was opened under;
-- if that account is gone (cookie changed, cache cleared) it shows the reason instead.
describe(":CW completed", function()
    local said, shown, enrich_with

    package.loaded["codewars.config"] = {
        lang = "python",
        user = { username = "" },
        langs = require("codewars.config.langs"),
    }
    package.loaded["codewars.logger"] = {
        info = function() end,
        warn = function(msg) said[#said + 1] = tostring(msg) end,
        error = function() end,
        err = function() end,
        debug = function() end,
    }
    package.loaded["codewars.theme"] = nil
    package.loaded["codewars.cache.problemlist_utils"] = {
        collect_languages = function() return {} end,
        filter_by_language = function(items) return items end,
    }
    package.loaded["codewars.icons"] = {
        get = function() return { completed = "C", recent = "R", rank = "*" } end,
    }
    package.loaded["codewars.cache.completed"] = {
        get = function() return { { slug = "a", completedAt = "2026-01-01T00:00:00.000Z" } }, false end,
        update = function() end,
        enrich = function(items, cb) return enrich_with(items, cb) end,
    }
    package.loaded["codewars.picker.dropdown"] = {
        provider = function() return "select" end,
        open = function() end,
        _reset = function() end,
    }
    package.loaded["codewars.picker"] = nil
    local picker = require("codewars.picker")
    local real_show

    before_each(function()
        said, shown = {}, 0
        real_show = picker._show_kata_list
        picker._show_kata_list = function() shown = shown + 1 end
    end)

    after_each(function()
        picker._show_kata_list = real_show
    end)

    it("shows the enriched list as it always did", function()
        enrich_with = function(items, cb) cb(items) end
        picker.completed()
        vim.wait(500, function() return shown > 0 end)
        assert.are.equal(1, shown)
        assert.are.same({}, said)
    end)

    it("does not show a list for an account that is gone, and says why", function()
        enrich_with = function(items, cb) cb(items, { msg = "The account changed while kata details were being fetched." }) end
        picker.completed()
        vim.wait(100)
        assert.are.equal(0, shown, "showed the old account's kata")
        assert.are.equal(1, #said, vim.inspect(said))
        assert.truthy(said[1]:find("account", 1, true), said[1])
    end)
end)
