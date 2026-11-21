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
        assert.truthy(info[1]:find("2 comments [c] show", 1, true))
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
        assert.are.equal("● alice  1 kyu  ·  2026-06-05  ·  ▲ 2", l[1])
        assert.are.equal("  Nice", l[2])
        assert.are.equal("  ↳ bob  4 kyu  ·  2026-06-06   spoiler", l[4])
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
        assert.are.equal("● zed", lines(ui.comments_popup.bufnr)[1])
    end)

    describe("voting", function()
        local api = require("codewars.api.solutions")
        local real_vote = api.vote
        local calls
        before_each(function()
            calls = {}
            api.vote = function(s, label, cb)
                calls[#calls + 1] = { sol = s, label = label, cb = cb }
            end
        end)
        after_each(function() api.vote = real_vote end)

        it("shows the key hints and the voted icon, in real (not dimmed) colors", function()
            ui = Solutions:new({ sol({ voted = { best_practice = false, clever = true } }) }, "python")
            ui:show()
            local icon = require("codewars.icons").get().voted
            local l = lines(ui.info_popup.bufnr)[1]
            assert.truthy(l:find("Best Practices 487 [gb]", 1, true))
            assert.truthy(l:find(icon .. " Clever 168 [gv]", 1, true))
            assert.is_nil(l:find(icon .. " Best", 1, true))
            -- The box is not dimmed wholesale; the pieces carry their own groups.
            local wh = vim.api.nvim_get_option_value("winhighlight", { win = ui.info_popup.winid })
            assert.is_nil(wh:find("Normal:Comment", 1, true))
            local ns = vim.api.nvim_create_namespace("codewars_solutions_info")
            local marks = vim.api.nvim_buf_get_extmarks(ui.info_popup.bufnr, ns, 0, -1, { details = true })
            local groups = {}
            for _, m in ipairs(marks) do groups[m[4].hl_group] = true end
            assert.is_true(groups.codewars_ok, "voted icon/label should be green (codewars_ok)")
            assert.is_true(groups.codewars_hint_key, "key hints should use codewars_hint_key")
            assert.is_true(groups.codewars_normal, "labels should be normal text")
        end)

        it("voting updates the info box in place and keeps the code cursor where it was", function()
            local long = {}
            for i = 1, 100 do long[i] = ("line %d"):format(i) end
            ui = Solutions:new({ sol({ code = table.concat(long, "\n"), voted = { best_practice = false, clever = false } }) }, "python")
            ui:show()
            local code_win, code_buf = ui.popup.winid, ui.popup.bufnr
            vim.api.nvim_win_set_cursor(code_win, { 50, 0 })
            ui:vote("best_practice")
            assert.are.equal(1, #calls)
            assert.are.equal("best_practice", calls[1].label)
            assert.are.equal(ui.solutions[1], calls[1].sol)
            -- The API mutates the solution in place; only the info box redraws.
            calls[1].sol.votes.best_practice = 488
            calls[1].sol.voted.best_practice = true
            calls[1].cb({ best_practice = { count = 488, voted = true }, clever = { count = 168, voted = false } })
            local icon = require("codewars.icons").get().voted
            assert.truthy(lines(ui.info_popup.bufnr)[1]:find(icon .. " Best Practices 488 [gb]", 1, true))
            assert.are.equal(code_win, ui.popup.winid, "code pane was rebuilt")
            assert.are.equal(code_buf, ui.popup.bufnr)
            assert.are.same({ 50, 0 }, vim.api.nvim_win_get_cursor(code_win))
        end)

        -- A vote on a big kata can sit for 15 s; without feedback from the
        -- keypress there is no telling a slow request from a key that did
        -- not register.
        it("shows a spinner from the keypress until the reply, and reports the outcome on it", function()
            local Spinner = require("codewars.logger.spinner")
            local real_start = Spinner.start
            local spinners = {}
            Spinner.start = function(_, msg)
                local s = { msgs = { msg } }
                function s:update(m) self.msgs[#self.msgs + 1] = m end
                function s:success(m) self.done = "success"; self.msgs[#self.msgs + 1] = m end
                function s:error(m) self.done = "error"; self.msgs[#self.msgs + 1] = m end
                spinners[#spinners + 1] = s
                return s
            end
            ui = Solutions:new({ sol({ voted = { best_practice = false, clever = true } }) }, "python")
            ui:show()

            ui:vote("best_practice")
            assert.are.equal(1, #spinners)
            assert.are.equal("Voting Best Practices…", spinners[1].msgs[1])
            assert.is_nil(spinners[1].done, "spinner must stay up until the reply")
            -- The API reports a slow path through the progress hook.
            local api_call = calls[1]
            calls[1].cb({ best_practice = { count = 488, voted = true }, clever = { count = 168, voted = false } }, nil,
                "Codewars timed out answering; re-read the page instead")
            assert.are.equal("success", spinners[1].done)
            assert.truthy(spinners[1].msgs[#spinners[1].msgs]:find("Voted Best Practices (488) — Codewars timed out", 1, true))
            assert.is_not_nil(api_call)

            -- Retracting says so from the start; a failure ends on the spinner too.
            ui:vote("clever")
            assert.are.equal("Removing your Clever vote…", spinners[2].msgs[1])
            calls[2].cb(nil, { msg = "Session expired" })
            assert.are.equal("error", spinners[2].done)
            assert.truthy(spinners[2].msgs[#spinners[2].msgs]:find("Vote failed: Session expired", 1, true))

            Spinner.start = real_start
        end)

        it("binds the votes to two-key chords, never to bare b / v", function()
            ui = Solutions:new({ sol() }, "python")
            ui:show()
            local lhs = {}
            for _, m in ipairs(vim.api.nvim_buf_get_keymap(ui.popup.bufnr, "n")) do lhs[m.lhs] = true end
            assert.is_true(lhs["gb"] and lhs["gv"] or false)
            assert.is_nil(lhs["b"])
            assert.is_nil(lhs["v"])
        end)

        it("ignores a second press while a vote is in flight", function()
            ui = Solutions:new({ sol() }, "python")
            ui:show()
            ui:vote("clever")
            ui:vote("clever")
            assert.are.equal(1, #calls)
            calls[1].cb({ best_practice = { count = 487, voted = false }, clever = { count = 169, voted = true } })
            ui:vote("clever")
            assert.are.equal(2, #calls)
        end)

        it("a failed vote leaves the popup as it was", function()
            ui = Solutions:new({ sol() }, "python")
            ui:show()
            ui:vote("clever")
            calls[1].cb(nil, { msg = "Session expired" })
            assert.truthy(lines(ui.info_popup.bufnr)[1]:find("Clever 168 [gv]", 1, true))
            assert.is_not_nil(ui.popup)
        end)
    end)

    -- The stack used to be sized purely as a fraction of the editor: on an
    -- 80-column terminal the info line was cut off before its [c] hint, and
    -- on a 10-row one the top border landed above row 0.
    describe("small editors", function()
        local saved
        before_each(function() saved = { vim.o.columns, vim.o.lines } end)
        after_each(function()
            if ui then ui:close() end
            ui = nil
            vim.o.columns, vim.o.lines = saved[1], saved[2]
        end)

        it("widens the stack so the whole info line fits on 80 columns", function()
            vim.o.columns = 80
            ui = Solutions:new({ sol({ voted = { best_practice = true, clever = false } }) }, "python")
            ui:show()
            local line = lines(ui.info_popup.bufnr)[1]
            local box_w = vim.api.nvim_win_get_config(ui.info_popup.winid).width
            assert.is_true(box_w >= vim.fn.strdisplaywidth(line),
                ("info box %d cols narrower than its line (%d)"):format(box_w, vim.fn.strdisplaywidth(line)))
            assert.truthy(line:find("[c] show", 1, true))
            assert.is_true(box(ui.popup).col >= 0)
        end)

        it("never places the stack above row 0 or beyond the last row", function()
            vim.o.lines = 10
            ui = Solutions:new({ sol() }, "python")
            ui:show()
            local code, info = box(ui.popup), box(ui.info_popup)
            assert.is_true(code.row >= 0, ("code border row %d"):format(code.row))
            assert.is_true(info.row + info.height <= vim.o.lines, "stack runs past the bottom")
            ui:toggle_comments()
            local com = box(ui.comments_popup)
            assert.is_true(box(ui.popup).row >= 0)
            assert.is_true(com.row + com.height <= vim.o.lines)
        end)
    end)

    -- Each pane is a bordered popup, and nui draws the border one row above
    -- the content row it is given. Two panes therefore need 6 rows at the
    -- least (1 + 2 border, twice); the old geometry forced each content
    -- height to 1 anyway and drew the bottom pane past the last row.
    describe("geometry on short editors", function()
        local BORDER = 2
        local log = require("codewars.logger")
        local saved, real_log, said
        before_each(function()
            saved = { vim.o.columns, vim.o.lines, vim.o.cmdheight }
            real_log = { info = log.info, warn = log.warn }
            said = { info = {}, warn = {} }
            log.info = function(m) said.info[#said.info + 1] = tostring(m) end
            log.warn = function(m) said.warn[#said.warn + 1] = tostring(m) end
        end)
        after_each(function()
            if ui then ui:close() end
            ui = nil
            log.info, log.warn = real_log.info, real_log.warn
            vim.o.cmdheight, vim.o.columns, vim.o.lines = saved[3], saved[1], saved[2]
        end)

        -- An editor `cols` wide with `rows` usable rows (lines minus the
        -- command line, which is what the geometry reads).
        local function resize(cols, rows)
            vim.o.cmdheight = 1
            vim.o.columns = cols
            vim.o.lines = rows + vim.o.cmdheight
        end

        local function geometry(show_comments, solution)
            local s = Solutions:new({ sol() }, "python")
            s.show_comments = show_comments
            return s:geometry(solution)
        end

        -- The rows the pane really covers on screen, border included.
        local function covered(g)
            return { top = g.row - 1, bottom = g.row + g.height + 1 }
        end

        local function assert_on_screen(g, rows, label)
            local c = covered(g)
            assert.is_true(c.top >= 0, ("%s starts above row 0 (%d)"):format(label, c.top))
            assert.is_true(c.bottom <= rows,
                ("%s ends at row %d, past the %d usable rows"):format(label, c.bottom, rows))
        end

        it("keeps the sizes of a typical editor exactly", function()
            resize(120, 39)
            local code, info, comments = geometry(false)
            assert.are.same({ width = 96, height = 22, row = 6, col = 12 }, code)
            assert.are.same({ width = 96, height = 1, row = 30, col = 12 }, info)
            assert.is_nil(comments)

            code, info, comments = geometry(true)
            assert.are.same({ width = 96, height = 14, row = 6, col = 12 }, code)
            assert.is_nil(info)
            assert.are.same({ width = 96, height = 9, row = 22, col = 12 }, comments)
        end)

        it("keeps the sizes of the default 80x24 terminal exactly", function()
            resize(80, 23)
            local code, info, comments = geometry(false)
            assert.are.same({ width = 64, height = 11, row = 3, col = 8 }, code)
            assert.are.same({ width = 64, height = 1, row = 16, col = 8 }, info)
            assert.is_nil(comments)

            code, info, comments = geometry(true)
            assert.are.same({ width = 64, height = 8, row = 3, col = 8 }, code)
            assert.is_nil(info)
            assert.are.same({ width = 64, height = 4, row = 13, col = 8 }, comments)
        end)

        it("stacks both panes flush and on screen whenever the two of them fit", function()
            for rows = 6, 60 do
                resize(120, rows)
                for _, show_comments in ipairs({ false, true }) do
                    local code, info, comments = geometry(show_comments)
                    local second, other = info, comments
                    if show_comments then second, other = comments, info end
                    local label = ("rows=%d comments=%s"):format(rows, tostring(show_comments))
                    assert.is_not_nil(second, label .. ": second pane dropped although it fits")
                    assert.is_nil(other, label .. ": the other mode's pane must stay nil")
                    assert_on_screen(code, rows, label .. " code")
                    assert_on_screen(second, rows, label .. " second")
                    assert.are.equal(covered(code).bottom, covered(second).top, label .. ": not flush")
                    assert.are.equal(code.col, second.col)
                    assert.are.equal(code.width, second.width)
                end
            end
        end)

        it("drops the second pane and keeps the code pane on screen when only one fits", function()
            for rows = 3, 5 do
                resize(120, rows)
                for _, show_comments in ipairs({ false, true }) do
                    local code, info, comments = geometry(show_comments)
                    local label = ("rows=%d comments=%s"):format(rows, tostring(show_comments))
                    assert.is_nil(info, label .. ": info box")
                    assert.is_nil(comments, label .. ": comments pane")
                    assert.is_true(code.height >= 1, label .. ": code pane has no content row")
                    assert_on_screen(code, rows, label .. " code")
                end
            end
        end)

        it("gives the code pane every row that fits once the second pane is dropped", function()
            resize(120, 5)
            assert.are.equal(5 - BORDER, (geometry(false)).height)
            assert.are.equal(5 - BORDER, (geometry(true)).height)
        end)

        -- A bordered pane is 1 content row + BORDER. On 2 usable rows (3 lines
        -- with a 1-line command line) even one pane would reach into the
        -- command line, so there is no geometry at all.
        it("returns no pane when not even one bordered pane fits", function()
            resize(120, 2)
            for _, show_comments in ipairs({ false, true }) do
                local ok, code, info, comments = pcall(geometry, show_comments)
                assert.is_true(ok, tostring(code))
                assert.is_nil(code, "a pane that cannot fit must not be returned")
                assert.is_nil(info)
                assert.is_nil(comments)
            end
        end)

        it("fits one pane exactly on the smallest editor that can hold it", function()
            resize(120, 3)
            for _, show_comments in ipairs({ false, true }) do
                local code, info, comments = geometry(show_comments)
                assert.are.equal(1, code.height)
                assert.are.same({ top = 0, bottom = 3 }, covered(code), "bottom border must sit on the last usable row")
                assert.is_nil(info)
                assert.is_nil(comments)
            end
        end)

        it("opens nothing on a 2-row editor, and says why once", function()
            resize(120, 2)
            local wins = #vim.api.nvim_list_wins()
            ui = Solutions:new({ sol() }, "python")
            ui:show()
            assert.is_nil(ui.popup)
            assert.is_nil(ui.info_popup)
            assert.is_nil(ui.comments_popup)
            assert.are.equal(wins, #vim.api.nvim_list_wins(), "a window was opened")
            assert.are.equal(1, #said.warn)
            assert.truthy(said.warn[1]:find("Not enough room to show solutions", 1, true))
            assert.truthy(said.warn[1]:find("taller", 1, true))
        end)

        it("mounts one pane on a 3-row editor with its bottom border on the last usable row", function()
            resize(120, 3)
            ui = Solutions:new({ sol() }, "python")
            ui:show()
            assert.is_not_nil(ui.popup)
            assert.is_nil(ui.info_popup)
            local code = box(ui.popup)
            assert.are.equal(0, code.row)
            assert.are.equal(3, code.row + code.height, "bottom border is not on the last usable row")
            assert.are.same({}, said.warn)
        end)

        it("closes a popup that no longer fits when the editor shrank before a page turn", function()
            resize(120, 30)
            ui = Solutions:new({ sol(), sol() }, "python")
            ui:show()
            assert.is_not_nil(ui.popup)
            resize(120, 2)
            ui:jump_to(2)
            assert.is_nil(ui.popup)
            assert.are.equal(1, #said.warn)
        end)

        it("mounts only the code pane on a 5-row editor and the toggle does not error", function()
            resize(120, 5)
            ui = Solutions:new({ sol() }, "python")
            ui:show()
            assert.is_nil(ui.info_popup)
            assert.is_nil(ui.comments_popup)
            local code = box(ui.popup)
            assert.is_true(code.row >= 0)
            assert.is_true(code.row + code.height <= 5, "code pane runs past the last usable row")
            -- Votes redraw the info box; with none mounted that is a no-op.
            ui:draw_info(ui.solutions[1])

            ui:toggle_comments()
            assert.is_nil(ui.comments_popup)
            assert.are.equal(ui.popup.winid, vim.api.nvim_get_current_win(), "focus must fall back to the code pane")
            ui:toggle_comments()
            assert.is_nil(ui.info_popup)
        end)

        it("'c' says there is no room when the comments pane cannot be shown", function()
            resize(120, 5)
            ui = Solutions:new({ sol() }, "python")
            ui:show()
            ui:toggle_comments()
            assert.are.equal(1, #said.info)
            assert.truthy(said.info[1]:find("Not enough room to show comments", 1, true))
            assert.truthy(said.info[1]:find("taller", 1, true))
            assert.is_nil(ui.comments_popup)
            assert.is_not_nil(ui.popup, "the code pane stays open")
            -- The comments were not shown, so the next press asks again
            -- instead of silently toggling them off.
            assert.is_false(ui.show_comments)
            ui:toggle_comments()
            assert.are.equal(2, #said.info)
        end)

        it("'c' stays quiet when the comments pane fits", function()
            resize(120, 30)
            ui = Solutions:new({ sol() }, "python")
            ui:show()
            ui:toggle_comments()
            assert.is_not_nil(ui.comments_popup)
            assert.are.same({}, said.info)
            assert.are.same({}, said.warn)
        end)
    end)

    it("still accepts a plain list of code strings", function()
        ui = Solutions:new({ "return 1 -- one", "return 2 -- two" }, "lua")
        ui:show()
        assert.are.equal("return 1 -- one", lines(ui.popup.bufnr)[1])
        assert.truthy(lines(ui.info_popup.bufnr)[1]:find("0 comments", 1, true))
    end)
end)
