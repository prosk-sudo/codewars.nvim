--- The `indent` option as it reaches a kata: the starter Codewars seeds is
--- converted on its way into the file, and the solution buffer's options are
--- set to match. A language without a setting, and a file that already
--- exists, are both left exactly as they are.
local P = require("plenary.path")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

package.loaded["codewars.logger"] = {
    info = function() end,
    warn = function() end,
    error = function() end,
    err = function() end,
    debug = function() end,
}

local cfg = {
    user = { templates = { solution = {} }, indent = {} },
    lang = "python",
    langs = require("codewars.config.langs"),
    storage = { home = P:new(tmp), cache = P:new(tmp) },
}
package.loaded["codewars.config"] = cfg

local Kata = require("codewars-ui.kata")
local templates = require("codewars.templates")

describe("Kata indentation", function()
    local n = 0
    local TWO = "int f(int x) {\n  if (x) {\n    return 1;\n  }\n  return 0;\n}"
    local FOUR = "int f(int x) {\n    if (x) {\n        return 1;\n    }\n    return 0;\n}"

    --- Open a kata seeded with `starter`; `on_disk` pre-creates its file, the
    --- way a kata visited before looks.
    local function open(lang, ext, starter, on_disk)
        n = n + 1
        local slug = "indent-kata-" .. n
        if on_disk then
            cfg.storage.home:joinpath(slug .. "." .. ext):write(on_disk, "w")
        end
        local kata = Kata:new(slug, lang)
        kata.setup_code = starter
        kata:create_buffer()
        return kata
    end

    local function text(kata)
        return table.concat(vim.api.nvim_buf_get_lines(kata.bufnr, 0, -1, false), "\n")
    end

    before_each(function()
        templates.set_enabled(true)
        cfg.user = { templates = { solution = {} }, indent = { c = 4 } }
    end)

    after_each(function()
        pcall(vim.cmd, "tabclose")
    end)

    it("seeds a two-space starter at the configured four", function()
        assert.are.equal(FOUR, text(open("c", "c", TWO)))
    end)

    -- Three, because nothing else sets three: with a common width this held
    -- on any machine whose own ftplugin for the language agreed, whether or
    -- not the option did anything. It also pins the order -- the option is
    -- applied after the FileType event, so it wins over an ftplugin.
    it("sets the solution buffer's indent options to match", function()
        cfg.user.indent = { c = 3 }
        local kata = open("c", "c", TWO)
        assert.is_true(vim.bo[kata.bufnr].expandtab)
        assert.are.equal(3, vim.bo[kata.bufnr].shiftwidth)
        assert.are.equal(3, vim.bo[kata.bufnr].softtabstop)
    end)

    it("sets real tabs when asked", function()
        cfg.user.indent = { c = "tabs" }
        local kata = open("c", "c", TWO)
        assert.is_false(vim.bo[kata.bufnr].expandtab)
        assert.are.equal("int f(int x) {\n\tif (x) {\n\t\treturn 1;\n\t}\n\treturn 0;\n}", text(kata))
    end)

    it("leaves a language with no setting exactly as it came", function()
        local java = "class A {\n  int f() {\n    return 1;\n  }\n}"
        assert.are.equal(java, text(open("java", "java", java)))
    end)

    it("converts the starter inside a template too", function()
        cfg.user.templates.solution.c = "#include <stdio.h>\n\n{{starter}}\n"
        assert.are.equal("#include <stdio.h>\n\n" .. FOUR, text(open("c", "c", TWO)))
    end)

    it("converts with templates switched off", function()
        cfg.user.templates.solution.c = "#include <stdio.h>\n\n{{starter}}\n"
        templates.set_enabled(false)
        assert.are.equal(FOUR, text(open("c", "c", TWO)))
    end)

    -- Seeding never overwrites work in progress, and neither does this.
    it("does not touch a file that already exists", function()
        local mine = "int f(int x) {\n  return x ? 1 : 0;\n}"
        assert.are.equal(mine, text(open("c", "c", TWO, mine)))
    end)

    it("applies again on reset", function()
        local kata = open("c", "c", TWO)
        vim.api.nvim_buf_set_lines(kata.bufnr, 0, -1, false, { "scribble" })
        kata:reset_code()
        assert.are.equal(FOUR, text(kata))
    end)
end)
