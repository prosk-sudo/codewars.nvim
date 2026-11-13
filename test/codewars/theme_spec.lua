describe("theme highlights", function()
    local config_stub = { user = {}, langs = {} }
    package.loaded["codewars.config"] = config_stub
    package.loaded["codewars.theme"] = nil
    local theme = require("codewars.theme")

    local function hl(name, link)
        return vim.api.nvim_get_hl(0, { name = name, link = link })
    end

    before_each(function()
        config_stub.user = {}
        vim.api.nvim_set_hl(0, "Title", { fg = 0x112233, bg = 0x445566 })
        vim.api.nvim_set_hl(0, "Comment", { fg = 0x778899 })
        theme.setup()
    end)

    it("ships no hardcoded colors", function()
        for name, spec in pairs(theme._specs) do
            assert.is_nil(spec.fg, name)
            assert.is_nil(spec.bg, name)
        end
    end)

    it("links plain groups to the theme", function()
        assert.are.equal("Comment", hl("codewars_breadcrumb").link)
        assert.are.equal("Normal", hl("codewars_normal").link)
    end)

    it("styled groups take the target fg, never its bg", function()
        local h = hl("codewars_header")
        assert.are.equal(0x112233, h.fg)
        assert.is_true(h.bold)
        assert.is_nil(h.bg)
        assert.is_nil(h.link)
    end)

    it("language icons share one overridable group", function()
        assert.are.equal("codewars_lang", hl("codewars_lang_python").link)
        assert.are.equal("codewars_lang", hl("codewars_lang_rust").link)
        assert.are.equal("Special", hl("codewars_lang").link)
    end)

    it("an fg override wins over the link", function()
        config_stub.user = { theme = { codewars_breadcrumb = { fg = 0xff0000 } } }
        theme.setup()
        local h = hl("codewars_breadcrumb")
        assert.are.equal(0xff0000, h.fg)
        assert.is_nil(h.link)
    end)

    it("a style override keeps the theme fg", function()
        config_stub.user = { theme = { codewars_breadcrumb = { bold = true } } }
        theme.setup()
        local h = hl("codewars_breadcrumb")
        assert.are.equal(0x778899, h.fg)
        assert.is_true(h.bold)
    end)

    it("a link override replaces the spec", function()
        config_stub.user = { theme = { codewars_header = { link = "Comment" } } }
        theme.setup()
        assert.are.equal("Comment", hl("codewars_header").link)
    end)

    it("re-derives after a colorscheme change", function()
        vim.cmd("highlight clear")
        vim.api.nvim_set_hl(0, "Title", { fg = 0xabcdef })
        vim.cmd("doautocmd ColorScheme")
        assert.are.equal(0xabcdef, hl("codewars_header").fg)
        assert.are.equal("Comment", hl("codewars_breadcrumb").link)
    end)
end)
