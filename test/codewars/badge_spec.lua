local badge = require("codewars-ui.renderer.badge")

local function render(overrides)
    return badge.render(vim.tbl_extend("force", {
        username = "prosk",
        rank_name = "4 kyu",
        rank = -4,
        honor = 747,
        completed = 190,
    }, overrides or {}))
end

--- The byte slice a highlight covers, so we can prove it lands on the text it
--- claims rather than trusting the offsets by eye.
local function slice(result, hl)
    return result.lines[hl.row + 1]:sub(hl.col_start + 1, hl.col_end)
end

local function find_hl(result, group)
    for _, hl in ipairs(result.highlights) do
        if hl.hl == group then
            return hl
        end
    end
end

describe("badge.render", function()
    it("draws a frame whose rows are all the same display width", function()
        local result = render()
        local width = vim.fn.strdisplaywidth(result.lines[1])
        assert.are.equal(width, vim.fn.strdisplaywidth(result.lines[2]))
        assert.are.equal(width, vim.fn.strdisplaywidth(result.lines[3]))
        assert.are.equal(result.width, width)
    end)

    it("shows rank, username and honor", function()
        local text = table.concat(render().lines, "\n")
        assert.truthy(text:match("4 kyu"))
        assert.truthy(text:match("prosk"))
        assert.truthy(text:match("747"))
    end)

    it("keeps the completed count the real SVG badge leaves out", function()
        local text = table.concat(render().lines, "\n")
        assert.truthy(text:match("190 kata completed"))
    end)

    it("tints the frame and the rank with the rank colour", function()
        local rank_hl = require("codewars.theme").rank_hl(-4)
        assert.are.equal("codewars_rank_blue", rank_hl)

        local result = render({ rank = -4 })
        assert.is_not_nil(find_hl(result, rank_hl), "expected a highlight in the rank group")

        local covered = false
        for _, hl in ipairs(result.highlights) do
            if hl.hl == rank_hl and slice(result, hl):match("4 kyu") then
                covered = true
            end
        end
        assert.is_true(covered, "the rank colour must cover the rank text")
    end)

    it("puts highlight offsets on the right bytes despite multibyte borders", function()
        local result = render()
        local user_hl = find_hl(result, "codewars_header")
        assert.are.equal("prosk", slice(result, user_hl))
    end)

    it("truncates a long username instead of breaking the frame", function()
        local result = render({ username = string.rep("verylongname", 6) })
        local width = vim.fn.strdisplaywidth(result.lines[1])
        assert.are.equal(width, vim.fn.strdisplaywidth(result.lines[2]))
        assert.truthy(result.lines[2]:match("…"))
    end)

    it("falls back to the theme's rank string when the profile has no name", function()
        -- built directly: tbl_extend cannot override a key with nil, so the
        -- helper's default rank_name would survive and mask the fallback
        local result = badge.render({ username = "prosk", rank = -8, honor = 1, completed = 0 })
        assert.truthy(table.concat(result.lines, "\n"):match("8 kyu"))
    end)

    it("survives an unranked profile", function()
        local result = badge.render({ username = "prosk", honor = 0, completed = 0 })
        assert.are.equal(4, #result.lines)
        assert.are.equal(
            vim.fn.strdisplaywidth(result.lines[1]),
            vim.fn.strdisplaywidth(result.lines[2])
        )
    end)
end)
