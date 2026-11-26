describe("config.validate", function()
    local warnings = {}

    package.loaded["codewars.logger"] = {
        info = function() end,
        error = function() end,
        debug = function() end,
        warn = function(msg)
            table.insert(warnings, msg)
        end,
    }

    local config = require("codewars.config")

    -- config.user and config.default are the SAME table until apply() builds a
    -- merged copy, so every case goes through apply() rather than writing
    -- config.user directly — a direct write would mutate the default schema
    -- for the rest of this nvim process.
    before_each(function()
        warnings = {}
        config.apply({})
    end)

    it("rejects a language the plugin does not support", function()
        config.apply({ lang = "pythn" })
        assert.has_error(function()
            config.validate()
        end)
    end)

    it("names the offending language in the error", function()
        config.apply({ lang = "brainfuck" })
        local ok, err = pcall(config.validate)
        assert.is_false(ok)
        assert.truthy(tostring(err):find("brainfuck", 1, true))
    end)

    it("suggests a near miss before erroring", function()
        config.apply({ lang = "pyth" })
        pcall(config.validate)
        assert.truthy(#warnings > 0)
        assert.truthy(table.concat(warnings, " "):find("python", 1, true))
    end)

    it("accepts a supported language", function()
        config.apply({ lang = "ruby" })
        assert.has_no.errors(function()
            config.validate()
        end)
    end)

    it("rejects an unknown picker provider", function()
        config.apply({ picker = { provider = "fzf" } })
        local ok, err = pcall(config.validate)
        assert.is_false(ok)
        assert.truthy(tostring(err):find("fzf", 1, true))
    end)

    it("accepts the select and telescope picker providers", function()
        for _, provider in ipairs({ "select", "telescope" }) do
            config.apply({ picker = { provider = provider } })
            assert.has_no.errors(function()
                config.validate()
            end)
        end
    end)

    it("rejects a storage.path that is not a function", function()
        config.apply({ storage = { path = "python/%s.py" } })
        local ok, err = pcall(config.validate)
        assert.is_false(ok)
        assert.truthy(tostring(err):find("storage.path", 1, true))
    end)

    it("accepts a storage.path function", function()
        config.apply({ storage = { path = function(ctx) return ctx.slug end } })
        assert.has_no.errors(function()
            config.validate()
        end)
    end)

    it("accepts the shipped default when the user sets no language", function()
        config.apply({})
        assert.has_no.errors(function()
            config.validate()
        end)
    end)

    describe("the indent option", function()
        it("is fine left out", function()
            assert.has_no.errors(function() config.validate() end)
        end)

        it("accepts spaces or tabs per language", function()
            config.apply({ indent = { python = 4, c = 2, go = "tabs" } })
            assert.has_no.errors(function() config.validate() end)
        end)

        -- Kumite and the kata editor serve more languages than training does.
        it("accepts a language you can only write kumite or katas in", function()
            config.apply({ indent = { solidity = 4 } })
            assert.has_no.errors(function() config.validate() end)
        end)

        it("rejects a width it cannot use, naming the language", function()
            config.apply({ indent = { python = 12 } })
            local ok, err = pcall(config.validate)
            assert.is_false(ok)
            assert.truthy(tostring(err):find("indent.python", 1, true), tostring(err))
        end)

        it("rejects a language the plugin does not have", function()
            config.apply({ indent = { pyton = 4 } })
            local ok, err = pcall(config.validate)
            assert.is_false(ok)
            assert.truthy(tostring(err):find("pyton", 1, true), tostring(err))
        end)
    end)
end)
