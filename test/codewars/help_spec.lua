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
    it("aligns descriptions by display width", function()
        local col
        for _, l in ipairs(lines()) do
            local name, desc = l:match("^    (.-)%s%s+(%S.*)$")
            if name and desc and not name:match("^%s*$") then
                local at = vim.fn.strdisplaywidth(l:sub(1, l:find(desc, 1, true) - 1))
                col = col or at
                assert.are.equal(col, at, ("row %q starts its description at %d, not %d"):format(name, at, col))
            end
        end
        assert.is_not_nil(col, "no rows were checked")
    end)
end)
