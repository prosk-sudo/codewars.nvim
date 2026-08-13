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

    it("accepts the shipped default when the user sets no language", function()
        config.apply({})
        assert.has_no.errors(function()
            config.validate()
        end)
    end)
end)
