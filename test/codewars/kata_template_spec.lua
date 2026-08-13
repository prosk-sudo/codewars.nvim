--- Applying and removing a template on a buffer the user is already editing.
---
--- The switch itself is covered in template_spec; what matters here is the
--- buffer rewrite, which is the half that can destroy work. Both operations are
--- byte-exact or they refuse: once a buffer has drifted, no rule reliably says
--- which lines came from the template.
local P = require("plenary.path")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local messages = {}
package.loaded["codewars.logger"] = {
    info = function(msg) table.insert(messages, msg) end,
    warn = function() end,
    error = function() end,
    err = function() end,
    debug = function() end,
}

local cfg = {
    user = { templates = { solution = {} } },
    lang = "python",
    langs = require("codewars.config.langs"),
    storage = { home = P:new(tmp), cache = P:new(tmp) },
}
package.loaded["codewars.config"] = cfg

local Kata = require("codewars-ui.kata")
local templates = require("codewars.templates")
local TOKEN = templates.STARTER_TOKEN

describe("Kata template operations", function()
    local n = 0

    local function open(starter)
        n = n + 1
        local kata = Kata:new("tpl-kata-" .. n, "python")
        kata.setup_code = starter
        kata:create_buffer()
        return kata
    end

    local function text(kata)
        return table.concat(vim.api.nvim_buf_get_lines(kata.bufnr, 0, -1, false), "\n")
    end

    before_each(function()
        messages = {}
        templates.set_enabled(true)
        cfg.user = { templates = { solution = { python = "import os\n\n" .. TOKEN .. "\n" } } }
    end)

    after_each(function()
        pcall(vim.cmd, "tabclose")
    end)

    it("removes the template, leaving the code that was wrapped", function()
        local kata = open("def f():\n    return 1")
        assert.are.equal("import os\n\ndef f():\n    return 1", text(kata))

        assert.is_true(kata:retemplate("strip"))
        assert.are.equal("def f():\n    return 1", text(kata))
    end)

    it("keeps edits made inside the wrapper", function()
        local kata = open("def f():\n    return 1")
        vim.api.nvim_buf_set_lines(kata.bufnr, 2, 4, false, { "def f():", "    return 42" })

        assert.is_true(kata:retemplate("strip"))
        assert.are.equal("def f():\n    return 42", text(kata))
    end)

    it("puts the template back around the code", function()
        local kata = open("def f():\n    return 1")
        kata:retemplate("strip")

        assert.is_true(kata:retemplate("wrap"))
        assert.are.equal("import os\n\ndef f():\n    return 1", text(kata))
    end)

    it("refuses to strip an edited wrapper and says why", function()
        local kata = open("def f():\n    return 1")
        vim.api.nvim_buf_set_lines(kata.bufnr, 0, 1, false, { "import sys" })

        assert.is_false(kata:retemplate("strip"))
        assert.are.equal("import sys\n\ndef f():\n    return 1", text(kata))
        assert.truthy(messages[#messages]:find("no longer matches", 1, true))
    end)

    it("declines to nest a template that is already applied", function()
        local kata = open("def f():\n    return 1")

        assert.is_false(kata:retemplate("wrap"))
        assert.are.equal("import os\n\ndef f():\n    return 1", text(kata))
    end)

    it("refuses when the template has no token to wrap around", function()
        cfg.user = { templates = { solution = { python = "import os" } } }
        local kata = open("def f(): pass")

        assert.is_false(kata:retemplate("strip"))
        assert.truthy(messages[#messages]:find(TOKEN, 1, true))
    end)

    it("leaves the buffer alone when no template is configured", function()
        cfg.user = { templates = { solution = {} } }
        local kata = open("def f(): pass")

        assert.is_false(kata:retemplate("strip"))
        assert.are.equal("def f(): pass", text(kata))
    end)
end)
