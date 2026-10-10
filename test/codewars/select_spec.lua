-- The selection the kata list shows, lifted out of the telescope picker so a
-- command can take the first entry without opening a UI. Pure: items in,
-- items out, no state, no telescope.
describe("picker.select", function()
    local select = require("codewars.picker.select")

    local function kata(slug, rank, langs)
        return { slug = slug, id = slug .. "-id", name = slug, rank_id = rank,
            languages = langs or { "python" } }
    end

    local items = {
        kata("hard", -3), kata("easy-a", -8), kata("mid", -6, { "python", "rust" }),
        kata("easy-b", -8), kata("beta", nil), kata("rust-only", -7, { "rust" }),
    }

    describe("filter_by_rank", function()
        it("keeps every rank when none is chosen", function()
            assert.are.equal(#items, #select.filter_by_rank(items, nil))
        end)
        it("narrows to one rank", function()
            local got = vim.tbl_map(function(i) return i.slug end, select.filter_by_rank(items, -8))
            assert.are.same({ "easy-a", "easy-b" }, got)
        end)
        it("accepts a list of ranks", function()
            assert.are.equal(3, #select.filter_by_rank(items, { -8, -6 }))
        end)
        it("drops unranked kata when a rank is chosen", function()
            for _, i in ipairs(select.filter_by_rank(items, { -8, -7, -6, -5, -4, -3, -2, -1 })) do
                assert.is_not_nil(i.rank_id)
            end
        end)
    end)

    describe("sort_items", function()
        it("easiest puts -8 first and unranked last", function()
            local got = select.sort_items(items, "easiest")
            assert.are.equal(-8, got[1].rank_id)
            assert.is_nil(got[#got].rank_id)
        end)
        it("hardest puts -3 first and unranked still last", function()
            local got = select.sort_items(items, "hardest")
            assert.are.equal(-3, got[1].rank_id)
            assert.is_nil(got[#got].rank_id)
        end)
        it("keeps cache order within a rank", function()
            local got = select.sort_items(items, "easiest")
            assert.are.equal("easy-a", got[1].slug)
            assert.are.equal("easy-b", got[2].slug)
        end)
        it("shuffle is a permutation, not a mutation", function()
            local before = vim.tbl_map(function(i) return i.slug end, items)
            local got = select.sort_items(items, "shuffle")
            assert.are.equal(#items, #got)
            assert.are.same(before, vim.tbl_map(function(i) return i.slug end, items))
        end)
    end)

    describe("next", function()
        local sel = { lang = "python", rank = nil, sort = "easiest" }

        it("is the first entry the list would show", function()
            assert.are.equal("easy-a", select.next(items, sel, {}).slug)
        end)

        it("skips kata already completed, by slug or id", function()
            assert.are.equal("easy-b", select.next(items, sel, { ["easy-a"] = true }).slug)
            assert.are.equal("mid", select.next(items, sel, { ["easy-a"] = true, ["easy-b-id"] = true }).slug)
        end)

        it("respects the chosen rank", function()
            assert.are.equal("hard", select.next(items, { lang = "python", rank = -3, sort = "easiest" }, {}).slug)
        end)

        it("respects the chosen language", function()
            assert.are.equal("rust-only",
                select.next(items, { lang = "rust", rank = -7, sort = "easiest" }, {}).slug)
        end)

        it("returns nil when nothing unsolved is left", function()
            local done = { hard = true, ["easy-a"] = true, mid = true, ["easy-b"] = true, beta = true }
            assert.is_nil(select.next(items, sel, done))
        end)

        it("never returns a completed kata under shuffle either", function()
            local done = { hard = true, ["easy-a"] = true, mid = true, beta = true }
            for _ = 1, 20 do
                assert.are.equal("easy-b", select.next(items, { lang = "python", sort = "shuffle" }, done).slug)
            end
        end)
    end)

    describe("rank_label", function()
        it("names the ranks in kyu", function()
            assert.are.equal("All ranks", select.rank_label(nil))
            assert.are.equal("6 kyu", select.rank_label(-6))
            assert.are.equal("8,7 kyu", select.rank_label({ -8, -7 }))
        end)
    end)
end)
