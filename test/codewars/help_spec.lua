-- The help screen lists two kinds of thing in one table: :CW subcommands and
-- normal-mode keymaps. `g1 … g5` sat under AUTHORING A KATA, so it rendered as
-- `:CW g1 … g5` -- a command that does not exist.
describe("Command help", function()
    local cmd = require("codewars.command")

    local function lines()
        return (cmd._help_lines())
    end

    --- The rows under a heading, up to the next blank line.
    local function section(name)
        local out, inside = {}, false
        for _, l in ipairs(lines()) do
            if l:match("^%s%s" .. name .. "$") then
                inside = true
            elseif inside then
                if l == "" then break end
                table.insert(out, l)
            end
        end
        return out
    end

    it("never offers a keymap as a :CW subcommand", function()
        for _, l in ipairs(lines()) do
            assert.is_nil(l:match(":CW%s+g[%d?]"), ("keymap shown as a command: %q"):format(l))
            assert.is_nil(l:match(":CW%s+Ctrl"), ("keymap shown as a command: %q"):format(l))
        end
    end)

    it("documents every pane key and the help key", function()
        local rows = section("KATA EDITOR KEYS")
        assert.truthy(#rows >= 2, "the kata editor keys section is missing")

        local text = table.concat(rows, "\n")
        assert.truthy(text:match("g1"), "pane keys are not listed")
        assert.truthy(text:match("g%?"), "g? is not documented")
        -- Named the same way `:CW kata pane <name>` accepts them, so the two
        -- entries teach the same vocabulary.
        for _, pane in ipairs({ "answer", "setup", "fixture", "example", "description" }) do
            assert.truthy(text:find(pane, 1, true), ("pane %q is not named"):format(pane))
        end
    end)

    it("still shows real subcommands with their prefix", function()
        local found = false
        for _, l in ipairs(lines()) do
            if l:match(":CW%s+kata pane") then found = true end
        end
        assert.is_true(found, "kata pane lost its :CW prefix")
    end)

    -- "g1 … g5" is 7 columns but 9 bytes; padding by byte length left its
    -- description two columns left of every other row.
    -- The width was fixed at 75 while 13 rows rendered wider, so whether they
    -- wrapped or were cut off came down to the reader's 'wrap' setting.
    it("is wide enough for every row it renders", function()
        local ls = lines()
        local width = cmd._help_width(ls)
        local columns = math.max(40, vim.o.columns - 4)
        for _, l in ipairs(ls) do
            local w = vim.fn.strdisplaywidth(l)
            assert.is_true(w <= width or width == columns,
                ("row of %d columns does not fit a %d wide popup: %s"):format(w, width, l))
        end
    end)

    it("aligns descriptions by display width", function()
        local col, checked = nil, 0
        for _, l in ipairs(lines()) do
            -- Entry rows only: four spaces, then content.
            if l:match("^    %S") then
                -- A description follows a run of two or more spaces. A row
                -- whose padding clamped to ONE space has no such run -- and an
                -- earlier version of this test simply skipped those, which is
                -- exactly how the one overflowing row stayed invisible while
                -- the test claimed to guarantee alignment.
                local _, pad_end = l:find("%s%s+", 5)
                assert.is_not_nil(pad_end,
                    ("row %q has no padding run: DESC_COL is too narrow for it"):format(l))
                local at = vim.fn.strdisplaywidth(l:sub(1, pad_end))
                col = col or at
                assert.are.equal(col, at,
                    ("row %q starts its description at column %d, not %d"):format(l, at, col))
                checked = checked + 1
            end
        end
        assert.is_true(checked > 20, ("only %d rows were checked"):format(checked))
    end)
end)
