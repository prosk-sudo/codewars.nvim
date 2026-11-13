describe("menu katas page", function()
    package.loaded["codewars.config"] = {
        user = { keys = { toggle = { "q" } }, username = "" },
        lang = "python",
        langs = require("codewars.config.langs"),
        name = "codewars.nvim",
    }
    package.loaded["codewars.logger"] = {
        info = function() end, warn = function() end, error = function() end,
        err = function() end, debug = function() end,
    }
    package.loaded["codewars.cache.cookie"] = { get = function() return nil end }
    local called = 0
    package.loaded["codewars.command"] = { recent = function() called = called + 1 end }

    package.loaded["codewars-ui.renderer.menu"] = nil
    local Menu = require("codewars-ui.renderer.menu")

    it("has a Recent entry on r that opens :CW recent", function()
        local recent
        for _, button in ipairs(Menu:init().pages.katas) do
            if button.label == "Recent" then recent = button end
        end
        assert.is_not_nil(recent)
        assert.are.equal("r", recent.sc)
        recent.fn()
        assert.are.equal(1, called)
    end)
end)
