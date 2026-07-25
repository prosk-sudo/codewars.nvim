local confirm = require("codewars-ui.popup.confirm")

--- Leading spaces a centered line carries.
local function indent(line)
    return #(line:match("^ *") or "")
end

describe("confirm.layout", function()
    it("centers every line within the box", function()
        local box = confirm.layout("Convert this kumite into a new kata?", { confirm = "Convert" })
        for _, line in ipairs(box.lines) do
            if line ~= "" then
                local left = indent(line)
                local right = box.width - left - vim.fn.strdisplaywidth(vim.trim(line))
                -- odd leftovers land on the right, so allow a single column
                assert.is_true(math.abs(left - right) <= 1,
                    ("line not centered: %q (left=%d right=%d width=%d)"):format(line, left, right, box.width))
            end
        end
    end)

    it("shows the confirm and cancel keys", function()
        local text = table.concat(confirm.layout("Delete?", { confirm = "Delete" }).lines, "\n")
        assert.truthy(text:match("%[y%] Delete"))
        assert.truthy(text:match("%[n%] Cancel"))
    end)

    it("measures curly quotes and em dashes by display width, not bytes", function()
        -- The real prompts are full of these; #s would over-count and the
        -- text would sit visibly off-centre.
        local box = confirm.layout("Publish “musti” — really?", {})
        for _, line in ipairs(box.lines) do
            assert.is_true(vim.fn.strdisplaywidth(line) <= box.width,
                ("line overflows the box: %q"):format(line))
        end
    end)

    it("wraps a long message instead of overflowing", function()
        local long = string.rep("word ", 60)
        local box = confirm.layout(long, {})
        assert.is_true(box.width <= 72)
        assert.is_true(#box.lines > 4, "a long message should occupy several lines")
        for _, line in ipairs(box.lines) do
            assert.is_true(vim.fn.strdisplaywidth(line) <= box.width)
        end
    end)

    it("keeps a blank line between the message and the keys", function()
        local box = confirm.layout("Short?", {})
        assert.are.equal("", box.lines[1])
        assert.are.equal("", box.lines[#box.lines])
        assert.are.equal(box.height, #box.lines)
    end)

    it("honours explicit paragraph breaks", function()
        local box = confirm.layout("First line.\n\nSecond line.", {})
        local text = table.concat(box.lines, "\n")
        assert.truthy(text:match("First line%."))
        assert.truthy(text:match("Second line%."))
    end)
end)
