-- Templates reached kumite only through `:CW kumite new`, which renders one at
-- creation. A fork got the parent's code verbatim, and `:CW template on/off`
-- resolved a kata and nothing else, so inside a kumite it flipped the global
-- switch and left the buffer alone -- which reads as the feature being broken.
--
-- Scoped to code that is yours: a fork, or a kumite you started. Someone
-- else's kumite is left exactly as they wrote it, because the template is not
-- stripped before saving and would otherwise end up in what you publish.
local Kumite = require("codewars-ui.kumite")

local TEMPLATE = "import logging\nlog = logging.getLogger()\n\n{{starter}}\n"

describe("Kumite templates", function()
    local config = require("codewars.config")
    local templates = require("codewars.templates")
    local saved_templates, saved_enabled

    local function workspace(state, code)
        local w = Kumite:new({
            id = "6a63e7e085269ff93dc6332e",
            title = "musti",
            description = "",
            language = "python",
            code = code or "print(1)",
            fixture = "test",
            ["package"] = "",
            test_framework = "cw-2",
            state = "published",
        }, { state = state })
        w.bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(w.bufnr, 0, -1, false, vim.split(code or "print(1)", "\n"))
        return w
    end

    local function text_of(w)
        return table.concat(vim.api.nvim_buf_get_lines(w.bufnr, 0, -1, false), "\n")
    end

    before_each(function()
        saved_templates = config.user.templates
        saved_enabled = templates.is_enabled()
        config.user.templates = { solution = { python = TEMPLATE } }
        templates.set_enabled(true)
    end)

    after_each(function()
        config.user.templates = saved_templates
        templates.set_enabled(saved_enabled)
    end)

    describe("retemplate", function()
        it("wraps an editable kumite around its code", function()
            local w = workspace("local_fork", "print(1)")
            assert.is_true(w:retemplate("wrap"))

            local text = text_of(w)
            assert.truthy(text:find("import logging", 1, true))
            assert.truthy(text:find("print(1)", 1, true),
                "the existing code must survive the wrap")
        end)

        it("strips it back, leaving the code as it was", function()
            local w = workspace("local_fork", "print(1)")
            w:retemplate("wrap")
            assert.is_true(w:retemplate("strip"))
            assert.are.equal("print(1)", text_of(w))
        end)

        -- The template is not removed before save/publish, so wrapping code
        -- you cannot edit would put your preamble into someone else's kumite
        -- the moment you forked or converted it.
        it("refuses a kumite that is not yours", function()
            local w = workspace("published_view", "print(1)")
            assert.is_false(w:retemplate("wrap"))
            assert.are.equal("print(1)", text_of(w))
        end)

        it("says why when the buffer no longer matches", function()
            local w = workspace("local_fork", "print(1)")
            -- strip without a wrap: nothing to remove
            assert.is_false(w:retemplate("strip"))
        end)
    end)

    describe(":CW template", function()
        local cmd = require("codewars.command")

        it("acts on the kumite in the tab", function()
            local w = workspace("local_fork", "print(1)")
            local real = require("codewars.utils").curr_kumite
            require("codewars.utils").curr_kumite = function() return w end

            cmd.template_on()
            assert.truthy(text_of(w):find("import logging", 1, true))
            cmd.template_off()
            assert.are.equal("print(1)", text_of(w))

            require("codewars.utils").curr_kumite = real
        end)

        it("leaves someone else's kumite alone", function()
            local w = workspace("published_view", "print(1)")
            local real = require("codewars.utils").curr_kumite
            require("codewars.utils").curr_kumite = function() return w end

            cmd.template_on()
            assert.are.equal("print(1)", text_of(w))

            require("codewars.utils").curr_kumite = real
        end)
    end)
end)
