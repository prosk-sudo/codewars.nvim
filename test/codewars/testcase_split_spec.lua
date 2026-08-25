describe("TestcaseSplit:populate", function()
    local TestcaseSplit = require("codewars-ui.split.testcase")

    -- populate() only needs a bufnr and the kata handle — no NuiSplit mount,
    -- so the regression is testable headless.
    local function make_split(slug)
        local split = TestcaseSplit:new({ slug = slug, lang = "python" })
        split.bufnr = vim.api.nvim_create_buf(false, true)
        return split
    end

    it("names the buffer per kata so two mounted katas don't collide (E95)", function()
        local a = make_split("e95-kata-a")
        local b = make_split("e95-kata-b")
        a:populate("fixture a")
        b:populate("fixture b") -- raised E95 before the fix (fixed shared name)
        local name_a = vim.api.nvim_buf_get_name(a.bufnr)
        local name_b = vim.api.nvim_buf_get_name(b.bufnr)
        assert.are_not.equal(name_a, name_b)
        assert.truthy(name_a:find("e95-kata-a", 1, true))
        assert.truthy(name_b:find("e95-kata-b", 1, true))
    end)

    it("re-populating the same split keeps working", function()
        local a = make_split("e95-kata-c")
        a:populate("v1")
        a:populate("v2") -- renaming a buffer to its own name must not error
        assert.are.same({ "v2" }, vim.api.nvim_buf_get_lines(a.bufnr, 0, -1, false))
    end)

    it("two splits for the SAME kata never crash the mount", function()
        local a = make_split("e95-kata-d")
        local b = make_split("e95-kata-d")
        a:populate("x")
        b:populate("y") -- name already taken: guard must swallow, not abort
        assert.are.same({ "y" }, vim.api.nvim_buf_get_lines(b.bufnr, 0, -1, false))
    end)

    it("handles a kata without a slug", function()
        local a = TestcaseSplit:new({ lang = "python" })
        a.bufnr = vim.api.nvim_create_buf(false, true)
        a:populate("z")
        assert.are.same({ "z" }, vim.api.nvim_buf_get_lines(a.bufnr, 0, -1, false))
    end)
end)

-- hide() used to unmount, which deletes the buffer: the fixture is editable
-- with no on-disk copy, so a toggle threw away every test the user wrote
-- and show() repopulated the server's original.
describe("TestcaseSplit hide/show keeps edits", function()
    local TestcaseSplit = require("codewars-ui.split.testcase")

    it("edits survive a hide/show cycle and back content() while hidden", function()
        local split = TestcaseSplit:new({ slug = "toggle-kata", lang = "python" })
        split:mount()
        split:populate("original fixture")
        local buf = split.bufnr
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "assert my_edit == 1" })

        split:hide()
        assert.is_false(split.visible)
        assert.is_true(vim.api.nvim_buf_is_valid(buf), "buffer deleted on hide")
        assert.are.equal("assert my_edit == 1", split:content())

        split:show()
        assert.are.equal(buf, split.bufnr, "show() remounted a new buffer")
        assert.are.same({ "assert my_edit == 1" }, vim.api.nvim_buf_get_lines(split.bufnr, 0, -1, false))
        split:unmount()
    end)
end)

describe("TestcaseSplit:mount filetype", function()
    local TestcaseSplit = require("codewars-ui.split.testcase")

    local function mounted(lang)
        local split = TestcaseSplit:new({ slug = "ft-" .. lang, lang = lang })
        split:mount()
        local ft = vim.bo[split.bufnr].filetype
        split:unmount()
        return ft
    end

    it("uses the filetype NAME, not config.langs' file extension", function()
        -- config.langs stores ft = "py"; a buffer with filetype=py gets no
        -- highlighting. The split must end up as 'python'.
        assert.are.equal("python", mounted("python"))
        assert.are.equal("javascript", mounted("javascript"))
        assert.are.equal("ruby", mounted("ruby"))
    end)

    it("follows the fixture's language when it differs from the solution's", function()
        assert.are.equal("ruby", mounted("sql")) -- SQL kata tests are written in Ruby
    end)
end)
