-- Codewars' starter code is not consistently indented: the same language
-- arrives with two spaces on one kata and four on the next, while an editor
-- has one setting per filetype. The `indent` option names a style per
-- language. These cover reading a starter's own style, converting it, and
-- above all the cases where it must be left alone -- a wrong guess here
-- rewrites code.
describe("indent", function()
    local indent = require("codewars.indent")

    describe("detect", function()
        it("reads the unit from the shallowest indented line", function()
            assert.are.same({ tabs = false, width = 2 }, indent.detect("def f():\n  if x:\n    return 1"))
            assert.are.same({ tabs = false, width = 4 },
                indent.detect("class A {\n    int f() {\n        return 0;\n    }\n}"))
        end)

        it("reads tabs", function()
            assert.are.same({ tabs = true, width = 1 }, indent.detect("func f() {\n\tif x {\n\t\treturn\n\t}\n}"))
        end)

        it("says nothing when nothing is indented", function()
            assert.is_nil(indent.detect(""))
            assert.is_nil(indent.detect("x = 1\ny = 2"))
        end)

        it("refuses a mix of tabs and spaces", function()
            assert.is_nil(indent.detect("f() {\n\ta;\n    b;\n}")) -- across lines
            assert.is_nil(indent.detect("f() {\n\t  a;\n}")) -- within one
        end)

        -- Not a whole number of levels, so the unit is a guess.
        it("refuses an aligned continuation", function()
            assert.is_nil(indent.detect("def f(a,\n      b):\n    return a"))
        end)

        it("ignores blank and whitespace-only lines", function()
            assert.are.same({ tabs = false, width = 4 }, indent.detect("def f():\n    a = 1\n   \n\n    return a"))
        end)

        -- The shallowest indentation in these is a comment's alignment, not a
        -- level, and taking it as the unit made every space of the code a
        -- level: a four-space body came out sixteen wide.
        it("refuses a comment aligned shallower than the code", function()
            -- The shape of a real C starter: a boxed comment, one space in.
            assert.is_nil(indent.detect("/*----*\\\n |  hint  |\n\\*----*/\nint f(void)\n{\n    return 1;\n}"))
            assert.is_nil(indent.detect("/**\n * Sums.\n */\nint sum(int a, int b) {\n    return 0;\n}"))
            assert.is_nil(indent.detect('"""\n  Notes\n"""\ndef f():\n    pass'))
        end)

        it("refuses a line more than one level deeper than the one before it", function()
            assert.is_nil(indent.detect("def f(\n        a, b):\n    return a"))
        end)

        it("reads a starter that is indented from its first line", function()
            assert.are.same({ tabs = false, width = 2 }, indent.detect("  a = 1\n  if a:\n    b = 2"))
        end)
    end)

    describe("convert", function()
        local two = "def f(x):\n  if x:\n    return 1\n  return 0"
        local four = "def f(x):\n    if x:\n        return 1\n    return 0"
        local tabbed = "def f(x):\n\tif x:\n\t\treturn 1\n\treturn 0"

        it("widens two spaces to four", function()
            assert.are.equal(four, indent.convert(two, 4))
        end)

        it("narrows four spaces to two, keeping the block structure", function()
            assert.are.equal(two, indent.convert(four, 2))
        end)

        it("turns spaces into tabs, and tabs into spaces", function()
            assert.are.equal(tabbed, indent.convert(four, "tabs"))
            assert.are.equal(four, indent.convert(tabbed, 4))
        end)

        it("changes nothing but the leading whitespace", function()
            local src = "int f() {\r\n  return  1;  \r\n}\r\n"
            assert.are.equal("int f() {\r\n    return  1;  \r\n}\r\n", indent.convert(src, 4))
        end)

        it("leaves whitespace-only lines as they were", function()
            assert.are.equal("def f():\n    a = 1\n   \n    return a",
                indent.convert("def f():\n  a = 1\n   \n  return a", 4))
        end)

        it("leaves code alone when its indentation cannot be read", function()
            for _, src in ipairs({
                "f() {\n\ta;\n    b;\n}",
                "def f(a,\n      b):\n    return a",
                "x = 1",
                "/**\n * Sums.\n */\nint sum(int a, int b) {\n    return 0;\n}",
            }) do
                assert.are.equal(src, indent.convert(src, 2))
            end
        end)

        it("leaves code already in that style untouched", function()
            assert.are.equal(four, indent.convert(four, 4))
            assert.are.equal(tabbed, indent.convert(tabbed, "tabs"))
        end)

        it("is idempotent", function()
            local once = indent.convert(two, 4)
            assert.are.equal(once, indent.convert(once, 4))
        end)

        it("leaves an empty starter empty", function()
            assert.are.equal("", indent.convert("", 4))
        end)

        it("ignores a style it does not understand", function()
            for _, bad in ipairs({ 0, 9, 2.5, "wide", true }) do
                assert.are.equal(two, indent.convert(two, bad))
            end
        end)
    end)

    describe("buf_options", function()
        it("is spaces at one width", function()
            assert.are.same({ expandtab = true, shiftwidth = 4, softtabstop = 4, tabstop = 4 }, indent.buf_options(4))
        end)

        it("is real tabs, leaving their display width alone", function()
            local opts = indent.buf_options("tabs")
            assert.is_false(opts.expandtab)
            assert.are.equal(0, opts.shiftwidth)
            assert.is_nil(opts.tabstop)
        end)
    end)

    -- Checked at setup(): a typo here has no symptom of its own, the option
    -- just silently does nothing for that language.
    describe("check_config", function()
        local check = indent.check_config

        it("accepts spaces or tabs per language", function()
            assert.is_nil(check(nil))
            assert.is_nil(check({}))
            assert.is_nil(check({ python = 4, c = 2, go = "tabs" }))
        end)

        it("rejects a language the plugin does not have", function()
            local err = check({ pyton = 4 })
            assert.truthy(err and err:find("indent.pyton", 1, true), tostring(err))
        end)

        it("rejects anything that is not 1 to 8 spaces or tabs", function()
            for _, bad in ipairs({ 0, 9, 2.5, "4", "tab", true, {} }) do
                local err = check({ python = bad })
                assert.truthy(err and err:find("indent.python", 1, true), vim.inspect(bad) .. " -> " .. tostring(err))
            end
        end)

        it("rejects something that is not a table", function()
            assert.is_not_nil(check(4))
            assert.is_not_nil(check("tabs"))
        end)
    end)

    describe("with the option set", function()
        local config = require("codewars.config")

        after_each(function() config.apply({}) end)

        it("converts a starter for a configured language only", function()
            config.apply({ indent = { python = 4 } })
            assert.are.equal("def f():\n    return 1", indent.starter("python", "def f():\n  return 1"))
            assert.are.equal("f() {\n  return 1;\n}", indent.starter("c", "f() {\n  return 1;\n}"))
        end)
    end)
end)
