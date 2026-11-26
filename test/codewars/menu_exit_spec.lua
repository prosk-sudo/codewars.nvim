describe("menu exit", function()
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
    local stopped = 0
    package.loaded["codewars"] = { stop = function() stopped = stopped + 1 end }

    package.loaded["codewars-ui.renderer.menu"] = nil
    local Menu = require("codewars-ui.renderer.menu")
    local pages = Menu:init().pages

    for _, page in ipairs({ "main", "signin" }) do
        it(("exits on a single q on the %s page"):format(page), function()
            local exit
            for _, button in ipairs(pages[page]) do
                if button.label == "Exit" then exit = button end
            end
            assert.is_not_nil(exit)
            assert.are.equal("q", exit.sc)
            stopped = 0
            exit.fn()
            assert.are.equal(1, stopped)
        end)
    end

    -- A longer shortcut starting with q would make the q mapping wait again.
    it("has no other shortcut starting with q", function()
        for name, buttons in pairs(pages) do
            for _, button in ipairs(buttons) do
                if button.label ~= "Exit" then
                    assert.is_nil(button.sc:match("^q"), name .. ": " .. button.sc)
                end
            end
        end
    end)
end)
