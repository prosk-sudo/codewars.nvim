local choose = require("codewars-ui.popup.choose")

describe("choose.layout", function()
    it("numbers the first nine rows and leaves the rest selectable", function()
        local items = {}
        for i = 1, 11 do
            items[i] = { label = "Item " .. i }
        end
        local box = choose.layout("Pick", items)
        assert.truthy(box.lines[1]:match("^  1 Item 1$"))
        assert.truthy(box.lines[9]:match("^  9 Item 9$"))
        -- past nine there is no shortcut, but the row still renders
        assert.truthy(box.lines[10]:match("Item 10$"))
        assert.is_nil(box.lines[10]:match("^  %d"))
    end)

    it("sizes the box to the longest row and caps its height", function()
        local items = {}
        for i = 1, 30 do
            items[i] = { label = "x" }
        end
        items[1] = { label = string.rep("wide ", 8) }
        local box = choose.layout("Pick", items)
        assert.is_true(box.width <= 72)
        assert.is_true(box.width >= 30)
        assert.is_true(box.height <= 12, "tall lists must not run off screen")
        assert.are.equal(30, #box.lines, "every item stays in the buffer")
    end)

    it("fits the real kata field and rank lists", function()
        local kata = require("codewars.api.kata")
        local ranks = choose.layout("Estimated Rank", kata.RANKS)
        assert.are.equal(#kata.RANKS, #ranks.lines)
        assert.truthy(ranks.lines[2]:match("8 kyu"))

        local cats = choose.layout("Discipline", kata.CATEGORIES)
        assert.are.equal(5, #cats.lines)
        assert.truthy(cats.lines[1]:match("Fundamentals"))
        assert.truthy(cats.lines[5]:match("Puzzles"))
    end)
end)
