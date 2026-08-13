describe("templates.render", function()
    local warnings = {}

    package.loaded["codewars.logger"] = {
        info = function() end,
        error = function() end,
        debug = function() end,
        warn = function(msg)
            table.insert(warnings, msg)
        end,
    }

    local templates = require("codewars.templates")
    local TOKEN = templates.STARTER_TOKEN

    --- One config table for the whole file, mutated in place rather than
    --- swapped out. `codewars.utils` binds the config module at load time
    --- (utils.lua:1), so replacing package.loaded leaves it holding the old
    --- table and every extension lookup fails for a reason production never
    --- sees. `langs` is real for the same reason.
    local cfg = { user = {}, langs = require("codewars.config.langs") }
    package.loaded["codewars.config"] = cfg

    --- Swap the module out entirely — for the shapes render() must survive.
    --- Eleven existing spec files stub config with no `templates` key, so a
    --- blind index would break them far from the cause.
    local function with_config(tbl)
        package.loaded["codewars.config"] = tbl
    end

    local function solution(specs)
        package.loaded["codewars.config"] = cfg
        cfg.user = { templates = { solution = specs } }
    end

    before_each(function()
        warnings = {}
        templates._reset_warned()
        cfg.user = {}
        package.loaded["codewars.config"] = cfg
    end)

    describe("falling through to the starter", function()
        it("returns the starter unchanged when nothing is configured", function()
            assert.are.equal("def f(): pass", templates.render("python", { starter = "def f(): pass" }))
        end)

        it("tolerates a config table with no templates key", function()
            with_config({ user = { keys = { toggle = { "q" } } }, lang = "python" })
            assert.are.equal("starter", templates.render("python", { starter = "starter" }))
        end)

        it("tolerates config being absent entirely", function()
            with_config(nil)
            assert.are.equal("starter", templates.render("python", { starter = "starter" }))
        end)

        it("returns empty when there is no template and no starter", function()
            assert.are.equal("", templates.render("nim", { starter = "" }))
        end)
    end)

    describe("string specs", function()
        it("replaces entirely when the template has no token", function()
            solution({ python = "import os" })
            assert.are.equal("import os", templates.render("python", { starter = "def f(): pass" }))
        end)

        it("wraps the starter when the template has the token", function()
            solution({ python = "import os\n" .. TOKEN .. "\n# end" })
            local out = templates.render("python", { starter = "def f(): pass" })
            assert.are.equal("import os\ndef f(): pass\n# end", out)
        end)

        it("injects starter text containing % verbatim", function()
            -- The erlang fixture uses % as its comment character. Passing the
            -- injected text as gsub's replacement STRING would silently eat
            -- every marker, and %1 would expand to the whole match.
            local hostile = "% Test\n%access export\nreturn a %1 %% b"
            solution({ erlang = TOKEN })
            assert.are.equal(hostile, templates.render("erlang", { starter = hostile }))
        end)

        it("does not rescan injected text for the token", function()
            solution({ python = "top\n" .. TOKEN })
            local out = templates.render("python", { starter = "literal " .. TOKEN })
            assert.are.equal("top\nliteral " .. TOKEN, out)
        end)

        it("substitutes every occurrence of the token", function()
            solution({ python = TOKEN .. "\n---\n" .. TOKEN })
            assert.are.equal("S\n---\nS", templates.render("python", { starter = "S" }))
        end)
    end)

    describe("function specs", function()
        it("passes the context through and uses the return value", function()
            local seen
            solution({
                rust = function(ctx)
                    seen = ctx
                    return "// " .. ctx.name .. "\n" .. ctx.starter
                end,
            })
            local out = templates.render("rust", { lang = "rust", name = "Multiply", starter = "fn m() {}" })
            assert.are.equal("// Multiply\nfn m() {}", out)
            assert.are.equal("rust", seen.lang)
        end)

        it("advances to the starter when the function errors", function()
            solution({ python = function() error("boom") end })
            assert.are.equal("S", templates.render("python", { starter = "S" }))
        end)

        it("advances when the function returns nil", function()
            solution({ python = function() return nil end })
            assert.are.equal("S", templates.render("python", { starter = "S" }))
        end)

        it("advances when the function returns a non-string", function()
            solution({ python = function() return 42 end })
            assert.are.equal("S", templates.render("python", { starter = "S" }))
        end)

        it("still substitutes the token in a function's return", function()
            solution({ python = function() return "top\n" .. TOKEN end })
            assert.are.equal("top\nS", templates.render("python", { starter = "S" }))
        end)
    end)

    describe("context defaults", function()
        it("fills lang and ext from config.langs", function()
            local seen
            solution({ python = function(ctx) seen = ctx; return "x" end })
            templates.render("python", { starter = "" })
            assert.are.equal("python", seen.lang)
            assert.are.equal("py", seen.ext)
        end)

        it("tolerates a utils stub with no get_lang", function()
            package.loaded["codewars.utils"] = { parse_slug = function() end }
            solution({ python = function(ctx) return tostring(ctx.ext) end })
            assert.are.equal("nil", templates.render("python", { starter = "" }))
            package.loaded["codewars.utils"] = nil
        end)

        it("does not mutate the caller's context table", function()
            local ctx = { starter = "S" }
            solution({ python = TOKEN })
            templates.render("python", ctx)
            assert.is_nil(ctx.lang)
            assert.is_nil(ctx.ext)
        end)
    end)

    describe("has_template", function()
        it("is false when nothing is configured", function()
            assert.is_false(templates.has_template("python"))
        end)

        it("is false for a language with no entry", function()
            solution({ python = "import os" })
            assert.is_false(templates.has_template("ruby"))
        end)

        it("is true for a configured string spec", function()
            solution({ python = "import os" })
            assert.is_true(templates.has_template("python"))
        end)

        it("is true for a configured function spec without running it", function()
            local ran = false
            solution({ python = function() ran = true; return "x" end })
            assert.is_true(templates.has_template("python"))
            assert.is_false(ran)
        end)

        it("tolerates a config with no templates key", function()
            with_config({ user = {} })
            assert.is_false(templates.has_template("python"))
        end)
    end)

    describe("dropped-signature warning", function()
        it("warns when a template discards a non-empty starter", function()
            solution({ python = "import os" })
            templates.render("python", { starter = "def f(): pass" })
            assert.are.equal(1, #warnings)
            assert.truthy(warnings[1]:find(TOKEN, 1, true))
        end)

        it("warns only once per language per session", function()
            solution({ python = "import os" })
            templates.render("python", { starter = "def f(): pass" })
            templates.render("python", { starter = "def f(): pass" })
            assert.are.equal(1, #warnings)
        end)

        it("warns separately for a different language", function()
            solution({ python = "import os", ruby = "require 'set'" })
            templates.render("python", { starter = "def f(): pass" })
            templates.render("ruby", { starter = "def f; end" })
            assert.are.equal(2, #warnings)
        end)

        it("does not warn when the template wraps", function()
            solution({ python = TOKEN })
            templates.render("python", { starter = "def f(): pass" })
            assert.are.same({}, warnings)
        end)

        it("does not warn when there was no starter to drop", function()
            solution({ python = "import os" })
            templates.render("python", { starter = "" })
            assert.are.same({}, warnings)
        end)
    end)
end)
