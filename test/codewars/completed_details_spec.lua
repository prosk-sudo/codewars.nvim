-- Kata details cached for lists that show kata the catalogue lacks (:CW completed and unfinished).
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

    -- Details cached before names were kept: a rank and tags, no name.
    describe("details cached without a name", function()
        local completed, looked_up

        before_each(function()
            completed = require("codewars.cache.completed")
            completed.save_details({ multiply = { rank = { id = -7, name = "7 kyu" }, tags = { "Math" } } })
            looked_up = {}
            local kata_api = package.loaded["codewars.api.kata"]
            local get = kata_api.get
            kata_api.get = function(slug, cb)
                looked_up[#looked_up + 1] = slug
                return get(slug, cb)
            end
        end)

        local function enrich(opts)
            local done = false
            completed.enrich({ { slug = "multiply" } }, function() done = true end, opts)
            vim.wait(200, function() return done end)
        end

        it("are looked up again when the caller needs names", function()
            enrich({ names = true })
            assert.are.same({ "multiply" }, looked_up)
            local d = completed.get_details().multiply
            assert.are.equal("Name of multiply", d.name)
            assert.are.equal(-8, d.rank.id)
        end)

        it("are left as they are for a caller that does not", function()
            enrich()
            assert.are.same({}, looked_up)
            assert.is_nil(completed.get_details().multiply.name)
        end)
    end)
end)
