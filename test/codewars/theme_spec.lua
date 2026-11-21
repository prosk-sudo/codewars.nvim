describe("theme highlights", function()
    local config_stub = { user = {}, langs = {} }
    package.loaded["codewars.config"] = config_stub
    package.loaded["codewars.theme"] = nil
    local theme = require("codewars.theme")

    -- ColorScheme autocmds present before the plugin has set anything up:
    -- whatever the test runner registers itself. Telling the plugin's apart
    -- by id keeps the stacking check independent of the augroup's name.
    local before_setup = {}
    for _, au in ipairs(vim.api.nvim_get_autocmds({ event = "ColorScheme" })) do
        before_setup[au.id] = true
    end
    local function plugin_autocmds()
        return vim.tbl_filter(function(au)
            return not before_setup[au.id]
        end, vim.api.nvim_get_autocmds({ event = "ColorScheme" }))
    end

    -- link = true reads the group as written (a link stays a link);
    -- link = false follows the link to the effective definition.
    local function raw(name)
        return vim.api.nvim_get_hl(0, { name = name, link = true })
    end
    local function resolved(name)
        return vim.api.nvim_get_hl(0, { name = name, link = false })
    end

    -- A real `:colorscheme`: a file on the runtimepath that clears every
    -- group and then defines Comment, the way a colorscheme does.
    local scheme_dir = vim.fn.tempname()
    vim.fn.mkdir(scheme_dir .. "/colors", "p")
    vim.opt.runtimepath:append(scheme_dir)

    local function use_colorscheme(comment_fg)
        local source = ([[
vim.cmd("highlight clear")
vim.g.colors_name = "cwtest"
vim.api.nvim_set_hl(0, "Comment", { fg = %d, ctermfg = 99 })
]]):format(comment_fg)
        vim.fn.writefile(vim.split(source, "\n"), scheme_dir .. "/colors/cwtest.lua")
        vim.cmd.colorscheme("cwtest")
    end

    before_each(function()
        config_stub.user = {}
        vim.api.nvim_set_hl(0, "Title", { fg = 0x112233, bg = 0x445566 })
        vim.api.nvim_set_hl(0, "Comment", { fg = 0x778899, ctermfg = 244 })
        theme.setup()
    end)

    describe("defaults", function()
        it("keep their fixed hex colors", function()
            assert.are.equal(0xb1361e, raw("codewars_header").fg)
            assert.is_true(raw("codewars_header").bold)
            assert.are.equal(0x866cc7, raw("codewars_rank_purple").fg)
            assert.are.equal(0x3776ab, raw("codewars_lang_python").fg)
            assert.are.equal(0xf7df1e, raw("codewars_lang_javascript").fg)
        end)

        it("are never links", function()
            for name in pairs(vim.api.nvim_get_hl(0, {})) do
                if name:find("^codewars_") then
                    assert.is_nil(raw(name).link, name)
                end
            end
        end)
    end)

    describe("overrides", function()
        it("an fg-only override still merges with the default", function()
            config_stub.user = { theme = { codewars_header = { fg = "#00ff00" } } }
            theme.setup()
            local h = raw("codewars_header")
            assert.are.equal(0x00ff00, h.fg)
            assert.is_true(h.bold) -- kept from the default spec
            assert.is_nil(h.link)
        end)

        it("a link-only override becomes a real link", function()
            config_stub.user = { theme = { codewars_header = { link = "Comment" } } }
            theme.setup()
            local h = raw("codewars_header")
            assert.are.equal("Comment", h.link)
            -- replaced, not merged: nothing of the default spec is left
            assert.is_nil(h.fg)
            assert.is_nil(h.bold)
            assert.are.equal(0x778899, resolved("codewars_header").fg)
        end)

        it("a link plus style keys takes the target fg and the style", function()
            config_stub.user = { theme = { codewars_breadcrumb = { link = "Title", italic = true } } }
            theme.setup()
            local h = raw("codewars_breadcrumb")
            assert.are.equal(0x112233, h.fg)
            assert.is_true(h.italic)
            assert.is_nil(h.link)
            assert.is_nil(h.bg) -- never the target's background
        end)

        it("a link plus style keys carries the target ctermfg", function()
            config_stub.user = { theme = { codewars_breadcrumb = { link = "Comment", bold = true } } }
            theme.setup()
            assert.are.equal(244, raw("codewars_breadcrumb").ctermfg)
        end)

        it("an explicit fg beats the link target's fg", function()
            config_stub.user = { theme = { codewars_breadcrumb = { link = "Comment", fg = "#ff0000", bold = true } } }
            theme.setup()
            assert.are.equal(0xff0000, raw("codewars_breadcrumb").fg)
        end)
    end)

    describe("on :colorscheme", function()
        it("keeps every codewars group set", function()
            vim.cmd.colorscheme("default")
            assert.are.equal(0x2cbe4e, raw("codewars_ok").fg)
            assert.are.equal(0xb1361e, raw("codewars_header").fg)
            assert.are.equal(0x3776ab, raw("codewars_lang_python").fg)
        end)

        it("keeps user overrides applied", function()
            config_stub.user = { theme = { codewars_header = { fg = "#00ff00" } } }
            theme.setup()
            vim.cmd.colorscheme("default")
            local h = raw("codewars_header")
            assert.are.equal(0x00ff00, h.fg)
            assert.is_true(h.bold)
        end)

        it("keeps a link override a link", function()
            config_stub.user = { theme = { codewars_header = { link = "Comment" } } }
            theme.setup()
            use_colorscheme(0xaabbcc)
            assert.are.equal("Comment", raw("codewars_header").link)
            assert.is_nil(raw("codewars_header").fg) -- still replaced, not merged
            assert.are.equal(0xaabbcc, resolved("codewars_header").fg)
        end)

        it("re-resolves a link plus style override from the new colorscheme", function()
            config_stub.user = { theme = { codewars_breadcrumb = { link = "Comment", bold = true } } }
            theme.setup()
            assert.are.equal(0x778899, raw("codewars_breadcrumb").fg)
            use_colorscheme(0xaabbcc)
            local h = raw("codewars_breadcrumb")
            assert.are.equal(0xaabbcc, h.fg)
            assert.are.equal(99, h.ctermfg)
            assert.is_true(h.bold)
        end)
    end)

    describe("setup", function()
        it("registers a ColorScheme autocmd in an augroup", function()
            local added = plugin_autocmds()
            assert.are.equal(1, #added)
            assert.is_not_nil(added[1].group_name)
        end)

        it("does not stack autocmds when called again", function()
            theme.setup()
            theme.setup()
            assert.are.equal(1, #plugin_autocmds())
        end)
    end)
end)
