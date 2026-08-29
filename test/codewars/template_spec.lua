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
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local cfg = {
        user = {},
        langs = require("codewars.config.langs"),
        storage = { cache = require("plenary.path"):new(tmp) },
    }
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
        templates.set_enabled(true)
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

    describe("is_configured", function()
        it("is false when nothing is configured", function()
            assert.is_false(templates.is_configured("python"))
        end)

        it("is false for a language with no entry", function()
            solution({ python = "import os" })
            assert.is_false(templates.is_configured("ruby"))
        end)

        it("is true for a configured string spec", function()
            solution({ python = "import os" })
            assert.is_true(templates.is_configured("python"))
        end)

        it("is true for a configured function spec without running it", function()
            local ran = false
            solution({ python = function() ran = true; return "x" end })
            assert.is_true(templates.is_configured("python"))
            assert.is_false(ran)
        end)

        it("tolerates a config with no templates key", function()
            with_config({ user = {} })
            assert.is_false(templates.is_configured("python"))
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

        it("does not warn when a function template splices the starter itself", function()
            solution({ python = function(ctx) return "# header\n" .. ctx.starter end })
            local out = templates.render("python", { starter = "def f(): pass" })
            assert.are.equal("# header\ndef f(): pass", out)
            assert.are.same({}, warnings)
        end)

        it("still warns when the starter is genuinely absent from the result", function()
            solution({ python = function() return "# header only" end })
            templates.render("python", { starter = "def f(): pass" })
            assert.are.equal(1, #warnings)
        end)

        it("does not warn when there was no starter to drop", function()
            solution({ python = "import os" })
            templates.render("python", { starter = "" })
            assert.are.same({}, warnings)
        end)
    end)

    describe("indented tokens", function()
        it("carries the token's indentation onto the starter's later lines", function()
            solution({ python = "def main():\n    " .. TOKEN .. "\n" })
            local out = templates.render("python", { starter = "def spacey(array):\n    return []" })
            assert.are.equal("def main():\n    def spacey(array):\n        return []\n", out)
        end)

        it("leaves a token at column zero alone", function()
            solution({ python = TOKEN })
            assert.are.equal("a\n  b", templates.render("python", { starter = "a\n  b" }))
        end)

        it("indents an occurrence on the first line of the template", function()
            solution({ python = "  " .. TOKEN })
            assert.are.equal("  a\n  b", templates.render("python", { starter = "a\nb" }))
        end)

        it("indents each occurrence by its own prefix", function()
            solution({ python = "  " .. TOKEN .. "\n\t\t" .. TOKEN })
            assert.are.equal("  a\n  b\n\t\ta\n\t\tb", templates.render("python", { starter = "a\nb" }))
        end)

        it("does not add indentation to blank lines", function()
            solution({ python = "    " .. TOKEN })
            assert.are.equal("    a\n\n    b", templates.render("python", { starter = "a\n\nb" }))
        end)

        it("leaves whitespace-only lines untouched", function()
            solution({ python = "    " .. TOKEN })
            assert.are.equal("    a\n  \n    b", templates.render("python", { starter = "a\n  \nb" }))
        end)

        it("ignores a token that is not alone on its line", function()
            solution({ python = "x = " .. TOKEN })
            assert.are.equal("x = a\nb", templates.render("python", { starter = "a\nb" }))
        end)

        it("does not rescan indented injected text for the token", function()
            solution({ python = "    " .. TOKEN })
            assert.are.equal("    literal " .. TOKEN, templates.render("python", { starter = "literal " .. TOKEN }))
        end)
    end)

    describe("the enable switch", function()
        it("is on by default", function()
            assert.is_true(templates.is_enabled())
        end)

        it("returns the starter untouched while off", function()
            solution({ python = "import os\n" .. TOKEN })
            templates.set_enabled(false)
            assert.are.equal("S", templates.render("python", { starter = "S" }))
        end)

        it("does not change what is configured, only whether it is applied", function()
            solution({ python = "import os" })
            templates.set_enabled(false)
            assert.is_true(templates.is_configured("python"))
        end)

        it("persists to disk rather than to memory, so it survives a restart", function()
            templates.set_enabled(false)
            assert.is_false(templates.is_enabled())
            assert.is_true(cfg.storage.cache:joinpath("templates_off"):exists())

            templates.set_enabled(true)
            assert.is_true(templates.is_enabled())
            assert.is_false(cfg.storage.cache:joinpath("templates_off"):exists())
        end)
    end)

    describe("wrap and strip", function()
        local WRAPPED = "import os\ndef f():\n    return 1\n# end"

        it("wraps buffer text the way render wraps a starter", function()
            solution({ python = "import os\n" .. TOKEN .. "\n# end" })
            assert.are.equal(WRAPPED, templates.wrap("python", "def f():\n    return 1"))
        end)

        it("strip is the inverse of wrap", function()
            solution({ python = "import os\n" .. TOKEN .. "\n# end" })
            assert.are.equal("def f():\n    return 1", templates.strip("python", WRAPPED))
        end)

        it("works while the switch is off, which is when strip is needed", function()
            solution({ python = "import os\n" .. TOKEN .. "\n# end" })
            templates.set_enabled(false)
            assert.are.equal("def f():\n    return 1", templates.strip("python", WRAPPED))
        end)

        it("undoes the indentation the token added", function()
            solution({ python = "def main():\n    " .. TOKEN })
            local wrapped = templates.wrap("python", "a\n  b")
            assert.are.equal("def main():\n    a\n      b", wrapped)
            assert.are.equal("a\n  b", templates.strip("python", wrapped))
        end)

        it("strip refuses when the buffer no longer matches the template", function()
            solution({ python = "import os\n" .. TOKEN })
            local out, reason = templates.strip("python", "import sys\ndef f(): pass")
            assert.is_nil(out)
            assert.truthy(reason)
        end)

        it("strip refuses a template with no token, having nothing to strip around", function()
            solution({ python = "import os" })
            local out, reason = templates.strip("python", "import os")
            assert.is_nil(out)
            assert.truthy(reason:find(TOKEN, 1, true))
        end)

        it("refuses a template with more than one token", function()
            solution({ python = TOKEN .. "\n" .. TOKEN })
            local out, reason = templates.strip("python", "a\na")
            assert.is_nil(out)
            assert.truthy(reason)
        end)

        it("refuses when no template is configured", function()
            local out, reason = templates.wrap("python", "code")
            assert.is_nil(out)
            assert.truthy(reason)
        end)

        it("wrap reports text that is already wrapped rather than nesting it", function()
            solution({ python = "import os\n" .. TOKEN .. "\n# end" })
            local out, reason = templates.wrap("python", WRAPPED)
            assert.is_nil(out)
            assert.truthy(reason)
        end)

        it("passes kata metadata to a function template", function()
            solution({ python = function(ctx) return "# " .. tostring(ctx.name) .. "\n" .. TOKEN end })
            assert.are.equal("# Multiply\ncode", templates.wrap("python", "code", { name = "Multiply" }))
        end)
    end)

    -- Opening a kata has to put the cursor where the user came to write, and
    -- with a long template that is neither end of the buffer. wrap() already
    -- reports this for `:CW template on`; render() is the path taken when a
    -- kata is first opened and needs to report the same thing.
    describe("starter position", function()
        -- Through locate(), because that is what production reads: render()
        -- reports no position, and the buffer is the only source the cursor
        -- is ever placed from.
        local function pos_for(template, starter)
            solution({ python = template })
            return templates.locate("python", templates.render("python", { starter = starter }),
                { starter = starter })
        end

        -- ON the last character, not one past it: a template may put its own
        -- text after the starter on that same line.
        it("reports where the starter ends", function()
            local pos = pos_for("import x\n\n" .. TOKEN .. "\n", "def f():\n    return 1")
            assert.are.same({ 4, #"    return 1" - 1, 3, 0 },
                { pos.row, pos.col, pos.start_row, pos.start_col })
        end)

        it("stays on the user's last character when the template continues on that line", function()
            local pos = pos_for("return " .. TOKEN .. ";\n", "a + b")
            assert.are.same({ 1, #"return a + b" - 1, 1, #"return " },
                { pos.row, pos.col, pos.start_row, pos.start_col }) -- the "b", not the ";"
        end)

        -- A row alone cannot separate preamble from code when the template
        -- puts both on one line.
        -- The whole reason this cannot just be "end of buffer".
        it("points at the starter, not EOF, when the template continues after it", function()
            local pos = pos_for("head\n" .. TOKEN .. "\nmain()\n", "def f():\n    return 1")
            assert.are.equal(3, pos.row)
            assert.are.equal(2, pos.start_row)
        end)

        it("accounts for indentation applied to the starter", function()
            local pos = pos_for("class C:\n    " .. TOKEN .. "\n", "def f():\n    return 1")
            assert.are.equal(3, pos.row)
            assert.are.equal(#"        return 1" - 1, pos.col)
        end)

        -- wrap/strip refuse a duplicated token outright ("no single place your
        -- code lives"), so a template that opens fine would then refuse
        -- `:CW template off`. Say so at the point it is written, not later.
        it("warns once when the template has more than one token", function()
            solution({ python = TOKEN .. "\n---\n" .. TOKEN })
            templates.render("python", { starter = "code" })
            assert.are.equal(1, #warnings)
            assert.truthy(warnings[1]:find("more than one", 1, true))

            templates.render("python", { starter = "code" })
            assert.are.equal(1, #warnings) -- once per language per session
        end)

        it("does not warn about a single token", function()
            solution({ python = "import x\n" .. TOKEN })
            templates.render("python", { starter = "code" })
            assert.are.equal(0, #warnings)
        end)

        -- Trailing newlines separate the starter from what follows; they are
        -- not the last thing the user wrote. Measuring past them lands on the
        -- template's next character, which is the whole thing to avoid.
        it("ends on the last character the user wrote, not past a trailing newline", function()
            for _, case in ipairs({
                { "{" .. "{starter}};", "return 1\n", 1, "1", "trailing newline before a suffix" },
                { "PRE\n" .. TOKEN .. "POST", "def f():\n    return 1\n\n\n", 3, "1", "several blank lines" },
                { "PRE\n" .. TOKEN, "code\n\n", 2, "e", "blank lines, no suffix" },
            }) do
                solution({ python = case[1] })
                local text = templates.render("python", { starter = case[2] })
                local pos = templates.locate("python", text, { starter = case[2] })
                local line = vim.split(text, "\n", { plain = true })[pos.row]

                assert.are.equal(case[3], pos.row, case[5])
                assert.are.equal(case[4], line:sub(pos.col + 1, pos.col + 1), case[5])
            end
        end)

        -- The column is a byte offset, so stepping back one byte from the end
        -- lands inside the last character rather than on it.
        it("puts the end on the first byte of a multibyte character", function()
            local pos = pos_for("    return " .. TOKEN, "caf\xc3\xa9")
            local line = "    return caf\xc3\xa9"
            assert.are.equal(0xC3, line:byte(pos.col + 1))
        end)

        it("has no position when no template applies", function()
            solution({})
            local text = templates.render("python", { starter = "def f(): pass" })
            assert.are.equal("def f(): pass", text)
            assert.is_nil(templates.locate("python", text, { starter = "def f(): pass" }))
        end)
    end)
end)
