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
        -- set_templates reaches this for `off` as well, where advice to fork
        -- and apply a template answers the opposite question.
        it("words the read-only refusal for the direction asked", function()
            local w = workspace("published_view", "print(1)")
            local said = {}
            local log = require("codewars.logger")
            local real = log.info
            log.info = function(m) said[#said + 1] = tostring(m) end

            w:retemplate("wrap")
            w:retemplate("strip")
            log.info = real

            assert.are.equal(2, #said)
            assert.truthy(said[1]:find("fork to apply", 1, true), said[1])
            assert.is_nil(said[2]:find("fork to apply", 1, true),
                "the strip refusal must not advise applying one: " .. said[2])
        end)

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

    -- set_lines moves every line under the cursor. After stripping a long
    -- preamble the window is still scrolled to where it used to be, so the
    -- buffer is right and the screen is not -- which reads as the command
    -- having done nothing, or as a second copy of the template. The kata path
    -- needed the same fix.
    -- fork() is the one caller of wrap() that is not a switch flip. wrap()
    -- deliberately ignores the enabled switch, because :CW template on calls
    -- it immediately after turning templates ON -- so an unguarded fork
    -- applies a template the user has turned off, and the template is never
    -- removed before save or publish.
    describe("forking", function()
        local function forkable(code)
            local w = workspace("published_view", code)
            w.clear_readonly_guard = function() end
            w.refresh_title = function() end
            w.autocmds = function() end
            w.fixture_split = { bufnr = vim.api.nvim_create_buf(false, true) }
            return w
        end

        it("applies the template", function()
            local w = forkable("print(1)")
            w:fork()
            assert.truthy(text_of(w):find("import logging", 1, true))
        end)

        it("does not apply one the user has turned off", function()
            -- Stubbed rather than set_enabled(): the switch is a file under
            -- config.storage.cache, which this harness does not create, so
            -- is_enabled would keep answering true.
            local real = templates.is_enabled
            templates.is_enabled = function() return false end

            local w = forkable("print(1)")
            w:fork()
            templates.is_enabled = real

            assert.are.equal("print(1)", text_of(w),
                "a fork must not wrap in a template that is switched off")
        end)

        -- The common case is no template at all. retemplate reports every
        -- refusal, which is right when the user asked for one and noise when
        -- forking asked on their behalf.
        it("says nothing when no template is configured", function()
            config.user.templates = { solution = {} }
            local said = {}
            local log = require("codewars.logger")
            local real = log.info
            log.info = function(m) said[#said + 1] = tostring(m) end

            local w = forkable("print(1)")
            w:fork()
            log.info = real

            for _, m in ipairs(said) do
                assert.is_nil(m:find("template is configured", 1, true),
                    "forking should not report a missing template: " .. m)
            end
            assert.are.equal("print(1)", text_of(w))
        end)
    end)

    describe("the view after a rewrite", function()
        local function windowed(state, code)
            local w = workspace(state, code)
            vim.cmd("tabnew")
            w.winid = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(w.winid, w.bufnr)
            return w
        end

        it("leaves the cursor on the code after a wrap", function()
            local w = windowed("local_fork", "print(1)")
            vim.api.nvim_win_set_cursor(w.winid, { 1, 0 })

            assert.is_true(w:retemplate("wrap"))

            local row = vim.api.nvim_win_get_cursor(w.winid)[1]
            local line = vim.api.nvim_buf_get_lines(w.bufnr, row - 1, row, false)[1]
            assert.are.equal("print(1)", line,
                ("cursor sat on %q, not the code"):format(line))
            vim.cmd("tabclose!")
        end)

        -- A multi-line body on purpose: with a single line, nvim's own cursor
        -- clamping lands on it anyway and the assertion holds whether or not
        -- _settle_cursor ran at all.
        it("follows the code back down after a strip", function()
            local body = "a = 1\nb = 2\nprint(a + b)"
            local w = windowed("local_fork", body)
            w:retemplate("wrap")
            -- Park the cursor in the preamble, where a real edit session would
            -- leave it, then strip everything above the code away.
            vim.api.nvim_win_set_cursor(w.winid, { 2, 0 })

            assert.is_true(w:retemplate("strip"))

            local row = vim.api.nvim_win_get_cursor(w.winid)[1]
            local total = vim.api.nvim_buf_line_count(w.bufnr)
            assert.are.equal(total, row,
                ("cursor left at row %d of a %d line buffer"):format(row, total))
            assert.are.equal("print(a + b)",
                vim.api.nvim_buf_get_lines(w.bufnr, row - 1, row, false)[1])
            vim.cmd("tabclose!")
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
