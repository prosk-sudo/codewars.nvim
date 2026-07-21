describe("theme rank helpers", function()
    package.loaded["codewars.config"] = package.loaded["codewars.config"] or {
        user = {},
        langs = {},
    }
    package.loaded["codewars.logger"] = package.loaded["codewars.logger"] or {
        info = function() end,
        warn = function() end,
        error = function() end,
        err = function() end,
        debug = function() end,
    }

    local theme = require("codewars.theme")

    describe("rank_str", function()
        it("formats kyu ranks", function()
            assert.are.equal("7 kyu", theme.rank_str(-7))
        end)

        it("formats dan ranks", function()
            assert.are.equal("2 dan", theme.rank_str(2))
        end)

        it("returns 'beta' for vim.NIL (unranked beta kata)", function()
            assert.are.equal("beta", theme.rank_str(vim.NIL))
        end)

        it("returns 'beta' for nil", function()
            assert.are.equal("beta", theme.rank_str(nil))
        end)
    end)

    describe("rank_hl", function()
        it("maps numeric ranks to groups", function()
            assert.are.equal("codewars_rank_white", theme.rank_hl(-8))
            assert.are.equal("codewars_rank_blue", theme.rank_hl(-4))
        end)

        it("falls back to purple for vim.NIL and nil", function()
            assert.are.equal("codewars_rank_purple", theme.rank_hl(vim.NIL))
            assert.are.equal("codewars_rank_purple", theme.rank_hl(nil))
        end)
    end)
end)
