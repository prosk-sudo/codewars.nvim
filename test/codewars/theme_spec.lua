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

    local function define_colorscheme_groups()
        vim.api.nvim_set_hl(0, "Title", { fg = 0x112233, bg = 0x445566 })
        vim.api.nvim_set_hl(0, "Comment", { fg = 0x778899, ctermfg = 244 })
    end

    -- A cold start, like the first setup() of a session or the apply right
    -- after a `:colorscheme`: none of our groups is defined when apply() runs.
    local function setup_cold(overrides)
        vim.cmd("highlight clear")
        define_colorscheme_groups()
        config_stub.user = { theme = overrides }
        theme.setup()
    end

    before_each(function()
        config_stub.user = {}
        define_colorscheme_groups()
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

    -- A styled link to another codewars group must not depend on which of the
    -- two apply() reaches first. apply() walks the groups in `pairs` order,
    -- which for this table follows the order they are declared in closely, so
    -- the chain is built both ways: each group linked to the one declared
    -- before it, and each linked to the one declared after it. In either case
    -- every link of one of the two chains has its target still unset when its
    -- source is applied, and a shuffled order will not satisfy a dozen links
    -- in a row by luck either.
    describe("styled links to other codewars groups", function()
        local DECLARED = {
            "codewars_lang_python",
            "codewars_lang_javascript",
            "codewars_lang_typescript",
            "codewars_lang_ruby",
            "codewars_lang_java",
            "codewars_lang_cpp",
            "codewars_lang_c",
            "codewars_lang_csharp",
            "codewars_lang_go",
            "codewars_lang_rust",
            "codewars_lang_haskell",
            "codewars_lang_clojure",
        }

        local function reversed(list)
            local out = {}
            for i = #list, 1, -1 do
                out[#out + 1] = list[i]
            end
            return out
        end

        local DIRECTIONS = {
            { name = "each linked to the group declared before it", chain = DECLARED },
            { name = "each linked to the group declared after it", chain = reversed(DECLARED) },
        }

        for _, direction in ipairs(DIRECTIONS) do
            local CHAIN = direction.chain

            -- CHAIN[1] gets `head` (nil: its default); every later group is a
            -- styled link to the one before it in CHAIN.
            local function chain_overrides(head)
                local overrides = { [CHAIN[1]] = head }
                for i = 2, #CHAIN do
                    overrides[CHAIN[i]] = { link = CHAIN[i - 1], italic = true }
                end
                return overrides
            end

            local function assert_chain_follows(fg, ctermfg)
                for i = 2, #CHAIN do
                    local h = raw(CHAIN[i])
                    assert.are.equal(fg, h.fg, CHAIN[i])
                    assert.are.equal(ctermfg, h.ctermfg, CHAIN[i])
                    assert.is_true(h.italic, CHAIN[i])
                    assert.is_nil(h.link, CHAIN[i])
                end
            end

            describe("a chain, " .. direction.name, function()
                it("follows the default color of its head", function()
                    setup_cold(chain_overrides(nil))
                    assert_chain_follows(raw(CHAIN[1]).fg, nil)
                end)

                it("follows a merged override on its head", function()
                    setup_cold(chain_overrides({ fg = "#010203" }))
                    assert_chain_follows(0x010203, nil)
                end)

                it("follows a link-only override on its head", function()
                    setup_cold(chain_overrides({ link = "Comment" }))
                    assert.are.equal("Comment", raw(CHAIN[1]).link)
                    assert_chain_follows(0x778899, 244)
                end)

                it("follows a styled link on its head", function()
                    setup_cold(chain_overrides({ link = "Title", bold = true }))
                    assert_chain_follows(0x112233, nil)
                end)

                it("follows a link-only override to another codewars group", function()
                    -- the last group declared, so no chain group comes after it
                    setup_cold(chain_overrides({ link = "codewars_lang_cfml" }))
                    assert_chain_follows(0xed2cd6, nil)
                end)

                it("gives the same result after a :colorscheme re-apply", function()
                    setup_cold(chain_overrides({ fg = "#010203" }))
                    vim.cmd.colorscheme("default")
                    assert_chain_follows(0x010203, nil)
                end)

                it("re-resolves a link-only head from the new colorscheme", function()
                    setup_cold(chain_overrides({ link = "Comment" }))
                    use_colorscheme(0xaabbcc)
                    assert_chain_follows(0xaabbcc, 99)
                end)
            end)
        end

        describe("that form a cycle", function()
            it("keeps only the style keys and does not error", function()
                local overrides = {
                    codewars_rank_white = { link = "codewars_rank_yellow", bold = true },
                    codewars_rank_yellow = { link = "codewars_rank_white", italic = true },
                }
                assert.has_no.errors(function()
                    setup_cold(overrides)
                end)
                local white, yellow = raw("codewars_rank_white"), raw("codewars_rank_yellow")
                assert.is_true(white.bold)
                assert.is_nil(white.fg)
                assert.is_nil(white.link)
                assert.is_true(yellow.italic)
                assert.is_nil(yellow.fg)
                assert.is_nil(yellow.link)
            end)

            it("covers a group that links to itself", function()
                local overrides = { codewars_rank_white = { link = "codewars_rank_white", bold = true } }
                assert.has_no.errors(function()
                    setup_cold(overrides)
                end)
                assert.is_true(raw("codewars_rank_white").bold)
                assert.is_nil(raw("codewars_rank_white").fg)
            end)

            it("gives a group that links into the cycle no color either", function()
                local overrides = {
                    codewars_rank_white = { link = "codewars_rank_yellow", bold = true },
                    codewars_rank_yellow = { link = "codewars_rank_white", italic = true },
                    codewars_rank_blue = { link = "codewars_rank_white", underline = true },
                }
                assert.has_no.errors(function()
                    setup_cold(overrides)
                end)
                assert.is_true(raw("codewars_rank_blue").underline)
                assert.is_nil(raw("codewars_rank_blue").fg)
            end)

            it("covers link-only overrides that point at each other", function()
                local overrides = {
                    codewars_rank_white = { link = "codewars_rank_yellow" },
                    codewars_rank_yellow = { link = "codewars_rank_white" },
                    codewars_rank_blue = { link = "codewars_rank_white", bold = true },
                }
                assert.has_no.errors(function()
                    setup_cold(overrides)
                end)
                assert.are.equal("codewars_rank_yellow", raw("codewars_rank_white").link)
                assert.is_true(raw("codewars_rank_blue").bold)
                assert.is_nil(raw("codewars_rank_blue").fg)
            end)

            it("survives a :colorscheme re-apply", function()
                local overrides = {
                    codewars_rank_white = { link = "codewars_rank_yellow", bold = true },
                    codewars_rank_yellow = { link = "codewars_rank_white", italic = true },
                }
                setup_cold(overrides)
                vim.cmd.colorscheme("default")
                assert.is_true(raw("codewars_rank_white").bold)
                assert.is_nil(raw("codewars_rank_white").fg)
                assert.is_true(raw("codewars_rank_yellow").italic)
                -- apply() ran to the end: a group after the cycle is still set
                assert.are.equal(0xb1361e, raw("codewars_header").fg)
            end)
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
