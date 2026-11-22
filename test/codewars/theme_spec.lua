describe("theme highlights", function()
    local config_stub = { user = {}, langs = {} }
    package.loaded["codewars.config"] = config_stub
    package.loaded["codewars.theme"] = nil

    -- Logger warn() messages, reset per test.
    local warnings = {}
    package.loaded["codewars.logger"] = {
        info = function() end,
        error = function() end,
        debug = function() end,
        warn = function(msg)
            table.insert(warnings, msg)
        end,
    }
    local theme = require("codewars.theme")

    -- ColorScheme autocmds that exist before setup (e.g. the runner's); filtering
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

    -- link = true reads a group as written; link = false follows its links.
    local function raw(name)
        return vim.api.nvim_get_hl(0, { name = name, link = true })
    end
    local function resolved(name)
        return vim.api.nvim_get_hl(0, { name = name, link = false })
    end

    -- A real `:colorscheme`: a runtimepath file that clears every group, then sets Comment.
    local scheme_dir = vim.fn.tempname()
    vim.fn.mkdir(scheme_dir .. "/colors", "p")
    vim.opt.runtimepath:append(scheme_dir)

    -- `aliases` (name -> definition): more groups the colorscheme sets after Comment.
    local function use_colorscheme(comment_fg, aliases)
        local source = ([[
vim.cmd("highlight clear")
vim.g.colors_name = "cwtest"
vim.api.nvim_set_hl(0, "Comment", { fg = %d, ctermfg = 99 })
for name, def in pairs(%s) do
    vim.api.nvim_set_hl(0, name, def)
end
]]):format(comment_fg, vim.inspect(aliases or {}))
        vim.fn.writefile(vim.split(source, "\n"), scheme_dir .. "/colors/cwtest.lua")
        vim.cmd.colorscheme("cwtest")
    end

    local function define_colorscheme_groups()
        vim.api.nvim_set_hl(0, "Title", { fg = 0x112233, bg = 0x445566 })
        vim.api.nvim_set_hl(0, "Comment", { fg = 0x778899, ctermfg = 244 })
    end

    -- A cold start (first setup() or right after `:colorscheme`): clear every group,
    -- then define `aliases` (name -> definition, ours or not) before setup().
    local function setup_cold(overrides, aliases)
        vim.cmd("highlight clear")
        define_colorscheme_groups()
        for name, def in pairs(aliases or {}) do
            vim.api.nvim_set_hl(0, name, def)
        end
        config_stub.user = { theme = overrides }
        theme.setup()
    end

    before_each(function()
        warnings = {}
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
            -- replaced, not merged
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

    -- `default` and `force` are dropped from a copy of `theme`, warning once per group.
    describe("overrides that carry `default` or `force`", function()
        local GREEN = 0x00ff00

        local function assert_one_warning(group, ...)
            assert.are.equal(1, #warnings)
            assert.truthy(warnings[1]:find(group, 1, true), warnings[1])
            for _, key in ipairs({ ... }) do
                assert.truthy(warnings[1]:find("`" .. key .. "`", 1, true), warnings[1])
            end
        end

        it("drops default: the override applies over an existing definition", function()
            setup_cold(
                { codewars_header = { fg = "#ff0000", default = true } },
                { codewars_header = { fg = GREEN } }
            )
            assert.are.equal(0xff0000, raw("codewars_header").fg)
            assert_one_warning("codewars_header", "default")
            assert.is_nil(warnings[1]:find("`force`", 1, true))
        end)

        it("drops force: the override is a real link", function()
            setup_cold({ codewars_header = { link = "Comment", force = true } })
            local h = raw("codewars_header")
            assert.are.equal("Comment", h.link)
            assert.is_nil(h.fg)
            assert_one_warning("codewars_header", "force")
            assert.is_nil(warnings[1]:find("`default`", 1, true))
        end)

        it("drops both keys with a single warning: the override is a real link", function()
            setup_cold(
                { codewars_header = { link = "Comment", default = true, force = true } },
                { codewars_header = { fg = GREEN } }
            )
            local h = raw("codewars_header")
            assert.are.equal("Comment", h.link)
            assert.is_nil(h.fg)
            assert_one_warning("codewars_header", "default", "force")
        end)

        it("gives a styled link to such a group the link target's color", function()
            setup_cold({
                codewars_lang_python = { link = "Comment", default = true, force = true },
                codewars_header = { link = "codewars_lang_python", italic = true },
            }, { codewars_lang_python = { fg = GREEN } })
            assert.are.equal("Comment", raw("codewars_lang_python").link)
            local h = raw("codewars_header")
            assert.are.equal(0x778899, h.fg)
            assert.are.equal(244, h.ctermfg)
            assert.is_true(h.italic)
            assert_one_warning("codewars_lang_python", "default", "force")
        end)

        it("gives the same result after a :colorscheme and does not warn again", function()
            local overrides = {
                codewars_lang_python = { link = "Comment", default = true, force = true },
                codewars_header = { link = "codewars_lang_python", italic = true },
            }
            setup_cold(overrides, { codewars_lang_python = { fg = GREEN } })
            assert.are.equal(1, #warnings)

            use_colorscheme(0xaabbcc, { codewars_lang_python = { fg = GREEN } })
            assert.are.equal("Comment", raw("codewars_lang_python").link)
            local h = raw("codewars_header")
            assert.are.equal(0xaabbcc, h.fg)
            assert.are.equal(99, h.ctermfg)

            vim.cmd.colorscheme("default")
            assert.are.equal("Comment", raw("codewars_lang_python").link)
            assert.are.equal(1, #warnings)
        end)

        it("leaves the user's theme table as it was", function()
            local user_theme = {
                codewars_header = { link = "Comment", default = true, force = true },
                codewars_ok = { fg = "#00ff00" },
            }
            local before = vim.deepcopy(user_theme)
            setup_cold(user_theme)
            assert.are.same(before, config_stub.user.theme)
            assert.is_true(config_stub.user.theme.codewars_header.default)
        end)

        it("warns again when setup() is called again", function()
            setup_cold({ codewars_header = { fg = "#ff0000", default = true } })
            theme.setup()
            assert.are.equal(2, #warnings)
        end)

        it("does not warn about overrides that carry neither key", function()
            setup_cold({
                codewars_header = { fg = "#00ff00" },
                codewars_ok = { link = "Comment", bold = true },
            })
            assert.are.equal(0, #warnings)
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

    -- The result must not depend on which group apply() reaches first. `pairs`
    -- order is unspecified, so chains are built in both declaration directions.
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

        local function mixed_case(name)
            local letters = 0
            return (name:gsub("%a", function(letter)
                letters = letters + 1
                return letters % 2 == 0 and letter:upper() or letter:lower()
            end))
        end

        local SPELLINGS = {
            { name = "in upper case", spell = string.upper },
            { name = "in mixed case", spell = mixed_case },
        }

        local DIRECTIONS = {
            { name = "each linked to the group declared before it", chain = DECLARED },
            { name = "each linked to the group declared after it", chain = reversed(DECLARED) },
        }

        for _, direction in ipairs(DIRECTIONS) do
            local CHAIN = direction.chain

            -- CHAIN[1] gets `head` (nil: its default); each later group is a styled
            -- link to the previous one, spelled by `spell`.
            local function chain_overrides(head, spell)
                spell = spell or function(name)
                    return name
                end
                local overrides = { [CHAIN[1]] = head }
                for i = 2, #CHAIN do
                    overrides[CHAIN[i]] = { link = spell(CHAIN[i - 1]), italic = true }
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
                    -- the last group declared, so no chain group follows it
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

            -- Names are case-insensitive: "CODEWARS_LANG_PYTHON" is a codewars group too.
            for _, spelling in ipairs(SPELLINGS) do
                local spell = spelling.spell

                describe("a chain, " .. direction.name .. ", links written " .. spelling.name, function()
                    it("follows the default color of its head", function()
                        setup_cold(chain_overrides(nil, spell))
                        assert_chain_follows(raw(CHAIN[1]).fg, nil)
                    end)

                    it("follows a merged override on its head", function()
                        setup_cold(chain_overrides({ fg = "#010203" }, spell))
                        assert_chain_follows(0x010203, nil)
                    end)

                    it("follows a link-only override on its head", function()
                        setup_cold(chain_overrides({ link = spell("codewars_lang_cfml") }, spell))
                        assert.are.equal("codewars_lang_cfml", raw(CHAIN[1]).link:lower())
                        assert_chain_follows(0xed2cd6, nil)
                    end)

                    it("gives the same result after a :colorscheme re-apply", function()
                        setup_cold(chain_overrides({ fg = "#010203" }, spell))
                        vim.cmd.colorscheme("default")
                        assert_chain_follows(0x010203, nil)
                    end)
                end)
            end

            -- Each chain link goes through `depth` groups that are not ours and ends
            -- in a codewars group named as `spell` spells it.
            local function alias_chain(head, depth, spell)
                local overrides = { [CHAIN[1]] = head }
                local aliases = {}
                for i = 2, #CHAIN do
                    local first = "CwAlias" .. i
                    overrides[CHAIN[i]] = { link = first, italic = true }
                    if depth == 2 then
                        aliases[first] = { link = "CwOuter" .. i }
                        aliases["CwOuter" .. i] = { link = spell(CHAIN[i - 1]) }
                    else
                        aliases[first] = { link = spell(CHAIN[i - 1]) }
                    end
                end
                return overrides, aliases
            end

            local function as_declared(name)
                return name
            end

            describe("a chain through other groups, " .. direction.name, function()
                it("follows the default color of its head", function()
                    local overrides, aliases = alias_chain(nil, 1, as_declared)
                    setup_cold(overrides, aliases)
                    assert_chain_follows(raw(CHAIN[1]).fg, nil)
                end)

                it("follows a merged override on its head through two groups per link", function()
                    local overrides, aliases = alias_chain({ fg = "#010203" }, 2, as_declared)
                    setup_cold(overrides, aliases)
                    assert_chain_follows(0x010203, nil)
                end)

                it("follows a styled link on its head", function()
                    local overrides, aliases = alias_chain({ link = "Title", bold = true }, 1, as_declared)
                    setup_cold(overrides, aliases)
                    assert_chain_follows(0x112233, nil)
                end)

                it("follows the head when the codewars names are written in mixed case", function()
                    local overrides, aliases = alias_chain({ fg = "#010203" }, 1, mixed_case)
                    setup_cold(overrides, aliases)
                    assert_chain_follows(0x010203, nil)
                end)

                it("gives the same result after a :colorscheme that defines the groups", function()
                    local overrides, aliases = alias_chain({ fg = "#010203" }, 1, as_declared)
                    setup_cold(overrides, aliases)
                    use_colorscheme(0x445566, aliases)
                    assert_chain_follows(0x010203, nil)
                end)

                it("re-resolves a link-only head from the new colorscheme", function()
                    local overrides, aliases = alias_chain({ link = "Comment" }, 2, as_declared)
                    setup_cold(overrides, aliases)
                    use_colorscheme(0xaabbcc, aliases)
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
                -- apply() ran to the end: an unrelated group is still set
                assert.are.equal(0xb1361e, raw("codewars_header").fg)
            end)

            -- A link back spelled in another case is the same cycle.
            it("counts a link back in another case as the same group", function()
                local overrides = {
                    codewars_rank_white = { link = "CODEWARS_RANK_YELLOW", bold = true },
                    codewars_rank_yellow = { link = "Codewars_Rank_White", italic = true },
                }
                assert.has_no.errors(function()
                    setup_cold(overrides)
                end)
                assert.is_true(raw("codewars_rank_white").bold)
                assert.is_nil(raw("codewars_rank_white").fg)
                assert.is_true(raw("codewars_rank_yellow").italic)
                assert.is_nil(raw("codewars_rank_yellow").fg)
            end)

            it("covers a group that links to itself in another case", function()
                local overrides = { codewars_rank_white = { link = "CODEWARS_RANK_WHITE", bold = true } }
                assert.has_no.errors(function()
                    setup_cold(overrides)
                end)
                assert.is_true(raw("codewars_rank_white").bold)
                assert.is_nil(raw("codewars_rank_white").fg)
            end)

            it("covers link-only overrides that point at each other in another case", function()
                local overrides = {
                    codewars_rank_white = { link = "CODEWARS_RANK_YELLOW" },
                    codewars_rank_yellow = { link = "Codewars_Rank_White" },
                    codewars_rank_blue = { link = "CODEWARS_RANK_WHITE", bold = true },
                }
                assert.has_no.errors(function()
                    setup_cold(overrides)
                end)
                -- the link is passed to Neovim as written; Neovim matches the name
                assert.are.equal("codewars_rank_yellow", raw("codewars_rank_white").link:lower())
                assert.is_true(raw("codewars_rank_blue").bold)
                assert.is_nil(raw("codewars_rank_blue").fg)
            end)

            it("survives a :colorscheme re-apply with links in another case", function()
                local overrides = {
                    codewars_rank_white = { link = "CODEWARS_RANK_YELLOW", bold = true },
                    codewars_rank_yellow = { link = "Codewars_Rank_White", italic = true },
                }
                setup_cold(overrides)
                vim.cmd.colorscheme("default")
                assert.is_true(raw("codewars_rank_white").bold)
                assert.is_nil(raw("codewars_rank_white").fg)
                assert.are.equal(0xb1361e, raw("codewars_header").fg)
            end)
        end)

        describe("through groups that are not ours", function()
            it("takes the fg of an alias of an alias that has its own fg", function()
                local aliases = {
                    CwOuter = { link = "CwInner" },
                    CwInner = { fg = 0x0a0b0c, ctermfg = 77 },
                }
                setup_cold({ codewars_rank_white = { link = "CwOuter", bold = true } }, aliases)
                local h = raw("codewars_rank_white")
                assert.are.equal(0x0a0b0c, h.fg)
                assert.are.equal(77, h.ctermfg)
                assert.is_true(h.bold)
            end)

            it("follows the link of a group that has both a link and an fg of its own", function()
                -- what Neovim itself does: the link wins over the group's own fg
                local aliases = { CwBoth = { link = "Comment", fg = 0x0a0b0c } }
                setup_cold({ codewars_rank_white = { link = "CwBoth", bold = true } }, aliases)
                assert.are.equal(0x778899, raw("codewars_rank_white").fg)
            end)

            it("gives no color to a cycle of such groups and does not error", function()
                local aliases = { CwA = { link = "CwB" }, CwB = { link = "CwA" } }
                assert.has_no.errors(function()
                    setup_cold({ codewars_rank_white = { link = "CwA", bold = true } }, aliases)
                end)
                assert.is_true(raw("codewars_rank_white").bold)
                assert.is_nil(raw("codewars_rank_white").fg)
            end)

            it("gives no color to a cycle through such a group and a codewars group", function()
                local aliases = { CwA = { link = "codewars_rank_yellow" } }
                local overrides = {
                    codewars_rank_yellow = { link = "CwA", italic = true },
                    codewars_rank_white = { link = "CwA", bold = true },
                }
                assert.has_no.errors(function()
                    setup_cold(overrides, aliases)
                end)
                assert.is_true(raw("codewars_rank_white").bold)
                assert.is_nil(raw("codewars_rank_white").fg)
                assert.is_true(raw("codewars_rank_yellow").italic)
                assert.is_nil(raw("codewars_rank_yellow").fg)
            end)

            it("survives a :colorscheme re-apply of such a cycle", function()
                local aliases = { CwA = { link = "CwB" }, CwB = { link = "CwA" } }
                setup_cold({ codewars_rank_white = { link = "CwA", bold = true } }, aliases)
                use_colorscheme(0x445566, aliases)
                assert.is_true(raw("codewars_rank_white").bold)
                assert.is_nil(raw("codewars_rank_white").fg)
                assert.are.equal(0xb1361e, raw("codewars_header").fg)
            end)

            it("takes the color of a codewars group whose override is itself a styled link", function()
                local aliases = { CwAlias = { link = "codewars_rank_yellow" } }
                local overrides = {
                    codewars_rank_yellow = { link = "Title", bold = true },
                    codewars_rank_white = { link = "CwAlias", italic = true },
                }
                setup_cold(overrides, aliases)
                assert.are.equal(0x112233, raw("codewars_rank_white").fg)
                -- a new colorscheme with another Title: the link follows it
                use_colorscheme(0x445566, vim.tbl_extend("force", aliases, { Title = { fg = 0x998877 } }))
                assert.are.equal(0x998877, raw("codewars_rank_white").fg)
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
