describe("cache.recent", function()
    local P = require("plenary.path")
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")

    package.loaded["codewars.logger"] = {
        info = function() end, warn = function() end, error = function() end,
        err = function() end, debug = function() end,
    }
    package.loaded["codewars.config"] = { user = {}, storage = { cache = P:new(tmp) } }
    package.loaded["codewars.cache.utils"] = nil
    package.loaded["codewars.cache.recent"] = nil
    local recent = require("codewars.cache.recent")
    local file = tmp .. "/recent.json"

    local function slugs()
        return vim.tbl_map(function(e) return e.slug .. ":" .. e.lang end, recent.get())
    end

    before_each(function()
        vim.fn.delete(file)
    end)

    it("is empty without a file", function()
        assert.are.same({}, recent.get())
    end)

    it("records newest first with name and rank", function()
        recent.record({ slug = "a", lang = "python", name = "A", rank = -8 })
        recent.record({ slug = "b", lang = "python" })
        assert.are.same({ "b:python", "a:python" }, slugs())
        local a = recent.get()[2]
        assert.are.equal("A", a.name)
        assert.are.equal(-8, a.rank)
        assert.is_number(a.opened_at)
    end)

    it("moves a re-opened kata to the top without duplicating it", function()
        recent.record({ slug = "a", lang = "python" })
        recent.record({ slug = "b", lang = "python" })
        recent.record({ slug = "a", lang = "python" })
        assert.are.same({ "a:python", "b:python" }, slugs())
    end)

    it("keeps the same kata in another language as its own entry", function()
        recent.record({ slug = "a", lang = "python" })
        recent.record({ slug = "a", lang = "rust" })
        assert.are.same({ "a:rust", "a:python" }, slugs())
    end)

    it("caps the list", function()
        for i = 1, recent.MAX + 5 do
            recent.record({ slug = "k" .. i, lang = "python" })
        end
        local items = recent.get()
        assert.are.equal(recent.MAX, #items)
        assert.are.equal("k" .. (recent.MAX + 5), items[1].slug)
    end)

    it("drops a non-numeric rank (vim.NIL for beta kata)", function()
        recent.record({ slug = "beta", lang = "python", rank = vim.NIL })
        assert.is_nil(recent.get()[1].rank)
    end)

    it("reads a corrupt file as empty and still records", function()
        vim.fn.writefile({ "{not json" }, file)
        assert.are.same({}, recent.get())
        recent.record({ slug = "a", lang = "python" })
        assert.are.same({ "a:python" }, slugs())
    end)

    it("never raises on bad input", function()
        assert.has_no.errors(function()
            recent.record(nil)
            recent.record({ slug = "a" })
        end)
        assert.are.same({}, recent.get())
    end)
end)
