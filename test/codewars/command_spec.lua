describe("command", function()
    -- Stub dependencies to avoid full plugin init
    package.loaded["codewars.config"] = {
        user = {
            keys = { toggle = { "q" } },
            logging = false,
            debug = false,
        },
        lang = "python",
        langs = {
            { slug = "python", name = "Python", ext = "py", comment = "#" },
            { slug = "javascript", name = "JavaScript", ext = "js", comment = "//" },
            { slug = "go", name = "Go", ext = "go", comment = "//" },
        },
    }
    package.loaded["codewars.logger"] = {
        info = function() end,
        warn = function() end,
        error = function() end,
        err = function() end,
        debug = function() end,
    }

    local cmd = require("codewars.command")

    describe("parse", function()
        it("splits simple args", function()
            local parts, options = cmd.parse("train multiply python")
            assert.are.equal(3, #parts)
            assert.are.equal("train", parts[1])
            assert.are.equal("multiply", parts[2])
            assert.are.equal("python", parts[3])
        end)

        it("detects key=value options", function()
            local parts, options = cmd.parse("list difficulty=8,7")
            assert.are.equal(2, #parts)
            assert.are.equal(1, #options)
            assert.are.equal("difficulty", options[1])
        end)
    end)

    describe("exec", function()
        it("parses positional args for train", function()
            -- We can't fully test exec without mocking the whole plugin,
            -- but we can test the arg parsing by checking what cmd.train receives
            local received_options
            local original_train = cmd.commands.train[1]
            cmd.commands.train[1] = function(opts) received_options = opts end

            cmd.exec({ name = "CW", args = "train multiply python" })

            assert.is_not_nil(received_options)
            assert.is_not_nil(received_options._positional)
            assert.are.equal("multiply", received_options._positional[1])
            assert.are.equal("python", received_options._positional[2])

            -- Restore
            cmd.commands.train[1] = original_train
        end)

        it("parses train with slug only", function()
            local received_options
            local original_train = cmd.commands.train[1]
            cmd.commands.train[1] = function(opts) received_options = opts end

            cmd.exec({ name = "CW", args = "train multiply" })

            assert.is_not_nil(received_options)
            assert.are.equal("multiply", received_options._positional[1])
            assert.is_nil(received_options._positional[2])

            cmd.commands.train[1] = original_train
        end)

        it("handles invalid command", function()
            local error_logged = false
            package.loaded["codewars.logger"].error = function() error_logged = true end

            cmd.exec({ name = "CW", args = "nonexistent" })

            assert.truthy(error_logged)
            package.loaded["codewars.logger"].error = function() end
        end)
    end)

    describe("complete", function()
        it("completes subcommands", function()
            local completions = cmd.complete("", "CW ")
            assert.truthy(vim.tbl_contains(completions, "train"))
            assert.truthy(vim.tbl_contains(completions, "test"))
            assert.truthy(vim.tbl_contains(completions, "submit"))
        end)

        it("completes language for train positional arg", function()
            local completions = cmd.complete("", "CW train multiply py")
            assert.truthy(vim.tbl_contains(completions, "python"))
        end)

        it("filters language completions", function()
            local completions = cmd.complete("", "CW train multiply go")
            assert.truthy(vim.tbl_contains(completions, "go"))
            assert.is_false(vim.tbl_contains(completions, "python"))
        end)
    end)
end)
