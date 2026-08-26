local P = require("plenary.path")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local cfg = {
    user = { templates = { solution = {} } },
    lang = "python",
    langs = require("codewars.config.langs"),
    storage = { home = P:new(tmp), cache = P:new(tmp) },
}
package.loaded["codewars.config"] = cfg

local templates = require("codewars.templates")
local filetypes = require("codewars.languages.filetypes")

local function with_template(spec)
    cfg.user.templates.solution.python = spec
end

describe("template wrap/strip round trip", function()
    it("finds the starter in a function template that splices ctx.starter", function()
        with_template(function(ctx)
            return "# hdr\n" .. ctx.starter .. "\n# ftr\n"
        end)
        local wrapped = templates.wrap("python", "code", { starter = "code" })
        assert.equals("# hdr\ncode\n# ftr", wrapped)
        assert.equals("code", templates.strip("python", wrapped, { starter = "code" }))
    end)

    it("keeps the user's trailing blank lines when the template has no suffix", function()
        with_template("# hdr\n{{starter}}")
        local wrapped = templates.wrap("python", "x\n\n")
        assert.equals("# hdr\nx\n\n", wrapped)
        assert.equals("x\n\n", templates.strip("python", wrapped))
    end)

    it("keeps trailing blank lines inside a template that has a suffix", function()
        with_template("H\n  {{starter}}\nF\n")
        local wrapped = templates.wrap("python", "x\n\n")
        assert.equals("H\n  x\n\n\nF", wrapped)
        assert.equals("x\n\n", templates.strip("python", wrapped))
    end)

    it("hands whitespace-only lines back untouched", function()
        with_template("def f():\n    {{starter}}\n")
        local wrapped = templates.wrap("python", "a\n  \nb")
        assert.equals("def f():\n    a\n  \n    b", wrapped)
        assert.equals("a\n  \nb", templates.strip("python", wrapped))
    end)

    it("never claims a bare {{starter}} template wraps a buffer", function()
        with_template("{{starter}}")
        local stripped, reason = templates.strip("python", "anything")
        assert.is_nil(stripped)
        assert.truthy(reason)
    end)
end)

describe("filetypes.test", function()
    it("ignores an empty testLanguage and maps nasm/sql to their test language", function()
        assert.equals(filetypes.test("nasm"), filetypes.test("nasm", ""))
        assert.equals("c", filetypes.test("nasm", ""))
        assert.equals("ruby", filetypes.test("sql", ""))
        assert.equals("python", filetypes.test("python", ""))
    end)
end)
