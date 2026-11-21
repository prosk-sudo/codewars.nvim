-- The plugin keeps its cookie, caches and kata stashes under
-- stdpath("cache") and the user's solutions under stdpath("data"). A spec
-- that saves anything without redirecting storage itself wrote into the
-- real ones: running the suite rewrote a kata stash in the developer's own
-- cache. minimal_init points every stdpath at a throwaway root instead.
describe("the test environment", function()
    it("keeps every Neovim directory the plugin writes to inside a throwaway root", function()
        local root = vim.env.CW_TEST_ROOT
        assert.is_string(root, "minimal_init did not set up a test root")
        for _, kind in ipairs({ "cache", "data", "state" }) do
            local dir = vim.fn.stdpath(kind)
            assert.are.equal(root, dir:sub(1, #root), ("stdpath(%q) is %s"):format(kind, dir))
        end
    end)

    it("so the plugin's own storage defaults land there too", function()
        package.loaded["codewars.config.template"] = nil
        local storage = require("codewars.config.template").storage
        local root = vim.env.CW_TEST_ROOT or "<unset>"
        assert.are.equal(root, storage.home:sub(1, #root), storage.home)
        assert.are.equal(root, storage.cache:sub(1, #root), storage.cache)
    end)
end)
