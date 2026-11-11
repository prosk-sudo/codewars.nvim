-- Kata details looked up from Codewars and cached for the lists that show a
-- kata the catalogue does not hold: :CW completed, and :CW unfinished.
local P = require("plenary.path")

describe("completed.enrich", function()
    local config = require("codewars.config")
    local saved_storage, saved_api, saved_spinner
    local tmp

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        saved_storage = config.storage
        config.storage = { home = P:new(tmp), cache = P:new(tmp) }
        saved_api = package.loaded["codewars.api.kata"]
        saved_spinner = package.loaded["codewars.logger.spinner"]
        package.loaded["codewars.api.kata"] = {
            get = function(slug, cb)
                cb({ name = "Name of " .. slug, rank = { id = -8, name = "8 kyu" }, tags = { "Fundamentals" } })
            end,
        }
        local quiet = { update = function() end, success = function() end, error = function() end }
        package.loaded["codewars.logger.spinner"] = { start = function() return quiet end }
    end)

    after_each(function()
        config.storage = saved_storage
        package.loaded["codewars.api.kata"] = saved_api
        package.loaded["codewars.logger.spinner"] = saved_spinner
        vim.fn.delete(tmp, "rf")
    end)

    it("keeps each kata's name with its rank, for a list that has nothing else to call it by", function()
        local completed = require("codewars.cache.completed")
        local done = false
        completed.enrich({ { slug = "multiply" } }, function() done = true end)
        vim.wait(200, function() return done end)
        local d = completed.get_details().multiply
        assert.are.equal("Name of multiply", d.name)
        assert.are.equal(-8, d.rank.id)
    end)
end)
