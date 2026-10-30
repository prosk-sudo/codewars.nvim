-- Every buffer that holds code you write -- a kata's solution, a kumite's
-- code, a kata editor's code panes -- goes through one setup, so none of them
-- can miss the `indent` option. Its order matters: setting the filetype runs
-- ftplugins, and whichever sets the indent options last is the one that holds.
describe("code buffers", function()
    local config = require("codewars.config")
    local ui_utils = require("codewars-ui.utils")

    after_each(function()
        config.apply({})
        vim.cmd("silent! tabonly!")
    end)

    local function scratch()
        return vim.api.nvim_create_buf(false, true)
    end

    describe("set_code_buffer", function()
        it("gives a buffer its language's filetype", function()
            local buf = scratch()
            ui_utils.set_code_buffer(buf, "python")
            assert.are.equal("python", vim.bo[buf].filetype)
        end)

        -- A kata's solution is a real file whose filetype was detected when
        -- it opened. Setting it again would run its ftplugins, and attach
        -- its language server, a second time.
        it("leaves a real file's detected filetype alone", function()
            local path = vim.fn.tempname() .. ".sh"
            vim.fn.writefile({ "echo hi" }, path)
            local buf = vim.fn.bufadd(path)
            vim.fn.bufload(buf)
            vim.bo[buf].filetype = "bash" -- detection's pick, not the map's "sh"
            local fired = 0
            local id = vim.api.nvim_create_autocmd("FileType", {
                buffer = buf,
                callback = function() fired = fired + 1 end,
            })
            ui_utils.set_code_buffer(buf, "shell")
            vim.api.nvim_del_autocmd(id)
            assert.are.equal("bash", vim.bo[buf].filetype)
            assert.are.equal(0, fired)
        end)

        -- The kata editor reuses a pane across a language switch.
        it("clears the filetype for a language with no grammar", function()
            local buf = scratch()
            vim.bo[buf].filetype = "python"
            ui_utils.set_code_buffer(buf, "bf")
            assert.are.equal("", vim.bo[buf].filetype)
        end)

        it("does not set a filetype the buffer already has", function()
            local buf = scratch()
            vim.bo[buf].filetype = "python"
            local fired = 0
            local id = vim.api.nvim_create_autocmd("FileType", {
                buffer = buf,
                callback = function() fired = fired + 1 end,
            })
            ui_utils.set_code_buffer(buf, "python")
            vim.api.nvim_del_autocmd(id)
            assert.are.equal(0, fired)
        end)

        it("sets the indent style after the filetype's own settings", function()
            config.apply({ indent = { python = 3 } })
            local buf = scratch()
            local id = vim.api.nvim_create_autocmd("FileType", {
                pattern = "python",
                callback = function(ev) vim.bo[ev.buf].shiftwidth = 7 end,
            })
            ui_utils.set_code_buffer(buf, "python")
            vim.api.nvim_del_autocmd(id)
            assert.are.same({ true, 3, 3, 3 },
                { vim.bo[buf].expandtab, vim.bo[buf].shiftwidth, vim.bo[buf].softtabstop, vim.bo[buf].tabstop })
        end)

        it("sets real tabs when asked", function()
            config.apply({ indent = { go = "tabs" } })
            local buf = scratch()
            ui_utils.set_code_buffer(buf, "go")
            assert.is_false(vim.bo[buf].expandtab)
            assert.are.equal(0, vim.bo[buf].shiftwidth)
        end)

        it("sets the other options it is given", function()
            local buf = scratch()
            ui_utils.set_code_buffer(buf, "python", { buftype = "acwrite", swapfile = false })
            assert.are.equal("acwrite", vim.bo[buf].buftype)
            assert.is_false(vim.bo[buf].swapfile)
        end)

        it("leaves indentation to the editor for a language with no setting", function()
            config.apply({ indent = { python = 3 } })
            local buf = scratch()
            vim.bo[buf].filetype = "c"
            vim.bo[buf].shiftwidth = 6
            ui_utils.set_code_buffer(buf, "c")
            assert.are.equal(6, vim.bo[buf].shiftwidth)
        end)
    end)

    -- Through the real mounts: these sites are where a code buffer could be
    -- created without the setup above.
    describe("in a kumite", function()
        it("sets the code buffer's indent style", function()
            config.apply({ indent = { python = 3 } })
            local Kumite = require("codewars-ui.kumite")
            local w = Kumite:new({
                id = "6a63e7e085269ff93dc6332e", title = "t", description = "", language = "python",
                code = "def f():\n    return 1", fixture = "test", ["package"] = "",
                test_framework = "cw-2", state = "published",
            }, { state = "local_fork" })
            w:mount()
            assert.are.equal(3, vim.bo[w.bufnr].shiftwidth)
        end)
    end)

    describe("in the kata editor", function()
        -- A fresh id each time: mount() focuses an open workspace for the
        -- same kata instead of building another.
        local opened = 0
        local function editor()
            opened = opened + 1
            local KataEditor = require("codewars-ui.kata_editor")
            local ws = KataEditor:new({
                id = ("6a63e7e085269ff93dc633%02d"):format(opened), language = "python", published = false,
                languages = {
                    python = {
                        id = "l", name = "python", answer = "def hi():\n    return 1", setup = "",
                        fixture = "test", example_fixture = "", ["package"] = "",
                    },
                },
                code_challenge = { name = "K", category = "algorithms", estimated_rank = "-6", tags_text = "", description = "d" },
                test_frameworks = { python = "cw-2" },
            })
            ws:mount()
            return ws
        end

        -- A kata's tests are not always written in the kata's language, so
        -- its test panes keep the editor's own settings.
        it("sets the code panes' indent style and leaves the test panes alone", function()
            config.apply({ indent = { python = 3 } })
            local ws = editor()
            assert.are.equal(3, vim.bo[ws.bufs.answer].shiftwidth)
            assert.are_not.equal(3, vim.bo[ws.bufs.fixture].shiftwidth)
        end)

        it("sets the new language's style on a switch", function()
            config.apply({ indent = { python = 3, ruby = 5 } })
            local ws = editor()
            ws:switch_language("ruby")
            assert.are.equal("ruby", vim.bo[ws.bufs.answer].filetype)
            assert.are.equal(5, vim.bo[ws.bufs.answer].shiftwidth)
        end)
    end)
end)
