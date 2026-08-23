-- The solutions popup grew an info box (votes, comment count) and a
-- comments pane. Mount the real thing headless: the previous popup was
-- untested, and a float that closes itself on BufLeave is exactly the kind
-- of code that breaks when more windows join it.
describe("Solutions popup", function()
    local Solutions = require("codewars-ui.popup.solutions")

    local function sol(overrides)
        return vim.tbl_deep_extend("force", {
            id = "56475c08593a1941660000b2",
            code = "def f(x):\n    return x",
            authors = { "alice", "bob" },
            extra_authors = 40,
            votes = { best_practice = 487, clever = 168 },
            total_comments = 2,
            comments = {
                { id = "c1", author = "alice", rank = "1 kyu", body = "Nice", created = "2026-06-05", score = 2, depth = 0, masked = false },
                { id = "c2", author = "bob", rank = "4 kyu", body = "reply", created = "2026-06-06", score = 0, depth = 1, masked = true },
            },
        }, overrides or {})
    end

    local function lines(bufnr)
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    -- Every pane gets a title (possibly empty) so nui draws its border in a
    -- separate window; that window's config is the on-screen box.
    local function box(popup)
        assert.is_not_nil(popup.border.winid, "pane has no border window")
        return vim.api.nvim_win_get_config(popup.border.winid)
    end

    local function title(popup)
        return popup.border._.text.top._content
    end

    local ui
    after_each(function()
        if ui then ui:close() end
        ui = nil
    end)

    it("shows the code alone, with no author line", function()
        ui = Solutions:new({ sol() }, "python")
        ui:show()
        assert.are.same({ "def f(x):", "    return x" }, lines(ui.popup.bufnr))
        assert.are.equal(" Solution 1/1 ", title(ui.popup))
    end)

    it("puts votes and the comment count in a one-line box flush under the code", function()
        ui = Solutions:new({ sol() }, "python")
        ui:show()
        local info = lines(ui.info_popup.bufnr)
        assert.are.equal(1, #info)
        assert.truthy(info[1]:find("Best Practices 487", 1, true))
        assert.truthy(info[1]:find("Clever 168", 1, true))
        assert.truthy(info[1]:find("2 comments  [c] show", 1, true))
        local code, box_info = box(ui.popup), box(ui.info_popup)
        -- Flush: no gap row, no overlap (the screenshots had both).
        assert.are.equal(code.row + code.height, box_info.row)
        assert.are.equal(code.col, box_info.col)
        assert.are.equal(code.width, box_info.width)
    end)

    it("highlights without setting a filetype, so no ftplugin or LSP runs", function()
        ui = Solutions:new({ sol() }, "python")
        ui:show()
        assert.are.equal("", vim.bo[ui.popup.bufnr].filetype)
        -- Either treesitter is driving the buffer or the syntax file is.
        local ts = vim.treesitter.highlighter.active[ui.popup.bufnr] ~= nil
        assert.is_true(ts or vim.bo[ui.popup.bufnr].syntax == "python")
    end)

    it("'c' replaces the info box with a comments pane flush under the code", function()
        ui = Solutions:new({ sol() }, "python")
        ui:show()
        assert.is_nil(ui.comments_popup)
        ui:toggle_comments()
        assert.is_nil(ui.info_popup, "info box must hide while the thread is open")
        assert.is_not_nil(ui.comments_popup)
        assert.are.equal(ui.comments_popup.winid, vim.api.nvim_get_current_win())
        assert.are.equal(" 2 comments  ·  [c] hide  ·  <Tab> switch pane ", title(ui.comments_popup))
        assert.are.equal("", vim.bo[ui.comments_popup.bufnr].filetype)
        local l = lines(ui.comments_popup.bufnr)
        assert.are.equal("● **alice**  _1 kyu · 2026-06-05 · ▲ 2_", l[1])
        assert.are.equal("  Nice", l[2])
        assert.are.equal("  ↳ **bob**  _4 kyu · 2026-06-06_  [spoiler]", l[4])
        assert.are.equal("    reply", l[5])
        local code, com = box(ui.popup), box(ui.comments_popup)
        assert.are.equal(code.row + code.height, com.row)
    end)

    it("'c' again brings the info box back; toggling on a solution without comments just says so", function()
        ui = Solutions:new({ sol(), sol({ total_comments = 0, comments = {} }) }, "python")
        ui:show()
        ui:toggle_comments()
        ui:toggle_comments()
        assert.is_nil(ui.comments_popup)
        assert.is_not_nil(ui.info_popup)
        ui:jump_to(2)
        ui:toggle_comments()
        assert.is_nil(ui.comments_popup)
        assert.truthy(lines(ui.info_popup.bufnr)[1]:find("0 comments", 1, true))
    end)

    it("moving focus between the panes does not close the popup", function()
        ui = Solutions:new({ sol() }, "python")
        ui:show()
        ui:toggle_comments()
        ui:switch_pane()
        assert.are.equal(ui.popup.winid, vim.api.nvim_get_current_win())
        vim.wait(50) -- let the scheduled BufLeave check run
        assert.is_not_nil(ui.popup)
        assert.is_not_nil(ui.comments_popup)
    end)

    it("leaving the panes altogether closes the popup", function()
        ui = Solutions:new({ sol() }, "python")
        ui:show()
        vim.cmd("new")
        vim.wait(50)
        assert.is_nil(ui.popup)
        assert.is_nil(ui.info_popup)
        vim.cmd("bdelete!")
    end)

    it("keeps the comments pane open when paging to the next solution", function()
        ui = Solutions:new({ sol(), sol({ comments = { { author = "zed", body = "second", depth = 0 } }, total_comments = 1 }) }, "python")
        ui:show()
        ui:toggle_comments()
        ui:jump_to(2)
        assert.is_not_nil(ui.comments_popup)
        assert.are.equal("● **zed**", lines(ui.comments_popup.bufnr)[1])
    end)

    it("still accepts a plain list of code strings", function()
        ui = Solutions:new({ "return 1 -- one", "return 2 -- two" }, "lua")
        ui:show()
        assert.are.equal("return 1 -- one", lines(ui.popup.bufnr)[1])
        assert.truthy(lines(ui.info_popup.bufnr)[1]:find("0 comments", 1, true))
    end)
end)
