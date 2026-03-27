local ConsolePopup = require("codewars-ui.popup.console")
local ui_utils = require("codewars-ui.utils")

local ns = vim.api.nvim_create_namespace("codewars_result")

---@class cw.ui.Console.ResultPopup : cw.ui.Console.Popup
local ResultPopup = ConsolePopup:extend("CwResultPopup")

---@param res table
function ResultPopup:handle(res)
    if not self.bufnr then return end

    local lines = {}
    local hl_lines = {}

    local function add(text, hl)
        table.insert(lines, text or "")
        if hl then
            table.insert(hl_lines, { #lines - 1, hl })
        end
    end

    local function add_separator()
        table.insert(lines, string.rep("─", 50))
        table.insert(hl_lines, { #lines - 1, "codewars_breadcrumb" })
    end

    local icons = require("codewars.icons").get()
    if res.valid then
        add(" " .. icons.all_passed .. " ALL TESTS PASSED", "codewars_ok")
    else
        add(" " .. icons.tests_failed .. " TESTS FAILED", "codewars_error")
    end
    add("")

    if res.summary then
        local parts = {}
        if res.summary.passed and res.summary.passed > 0 then
            table.insert(parts, ("Passed: %d"):format(res.summary.passed))
        end
        if res.summary.failed and res.summary.failed > 0 then
            table.insert(parts, ("Failed: %d"):format(res.summary.failed))
        end
        if res.summary.errors and res.summary.errors > 0 then
            table.insert(parts, ("Errors: %d"):format(res.summary.errors))
        end
        if res.wall_time then
            table.insert(parts, ("Time: %dms"):format(res.wall_time))
        end
        if #parts > 0 then
            add("  " .. table.concat(parts, "  |  "), "codewars_ref")
        end
        add("")
    end

    if res.output and res.output ~= "" then
        add_separator()
        add("  Test Results", "Title")
        add_separator()
        add("")

        local output_str = type(res.output) == "string" and res.output or vim.inspect(res.output)
        for _, line in ipairs(vim.split(output_str, "\n", { plain = true })) do
            table.insert(lines, line)
        end
        while #lines > 0 and lines[#lines] == "" do
            table.remove(lines)
        end
        add("")
    end

    if res.reason and tostring(res.reason) ~= "vim.NIL" then
        add_separator()
        add("  Error", "codewars_error")
        add_separator()
        add("")
        for line in tostring(res.reason):gmatch("[^\r\n]+") do
            table.insert(lines, "  " .. line)
        end
        add("")
    end

    if res.success_msg then
        add("")
        add("  " .. res.success_msg, "codewars_ok")
    end

    local clean = {}
    for _, line in ipairs(lines) do
        if line == nil then
        elseif type(line) ~= "string" then
            table.insert(clean, tostring(line))
        elseif line:find("\n") or line:find("\r") then
            for sub in line:gmatch("[^\r\n]+") do
                table.insert(clean, sub)
            end
        else
            table.insert(clean, line)
        end
    end

    ui_utils.buf_set_lines(self.bufnr, clean)
    vim.api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)

    for _, hl in ipairs(hl_lines) do
        if hl[1] < #clean then
            vim.api.nvim_buf_add_highlight(self.bufnr, ns, hl[2], hl[1], 0, -1)
        end
    end

    local pass_icon = vim.pesc(icons.test_passed)
    local fail_icon = vim.pesc(icons.test_failed)
    for i, line in ipairs(clean) do
        if line:match("^%s*PASSED:") or line:match(pass_icon) then
            vim.api.nvim_buf_add_highlight(self.bufnr, ns, "codewars_ok", i - 1, 0, -1)
        elseif line:match("^%s*FAILED:") or line:match("^%s*ERROR:") or line:match(fail_icon) then
            vim.api.nvim_buf_add_highlight(self.bufnr, ns, "codewars_error", i - 1, 0, -1)
        elseif line:match("^%s*Completed in") then
            vim.api.nvim_buf_add_highlight(self.bufnr, ns, "codewars_ref", i - 1, 0, -1)
        end
    end
end

function ResultPopup:handle_error(err)
    if not self.bufnr then return end

    local lines = { "== ERROR ==", "" }
    for line in (err.msg or "Unknown error"):gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    ui_utils.buf_set_lines(self.bufnr, lines)
    vim.api.nvim_buf_add_highlight(self.bufnr, -1, "codewars_error", 0, 0, -1)
end

function ResultPopup:clear(msg)
    if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
        ui_utils.buf_set_lines(self.bufnr, { msg or "Running tests..." })
    end
end

---@param parent cw.ui.Console
function ResultPopup:init(parent)
    ResultPopup.super.init(self, parent, {
        border = {
            style = "rounded",
            text = {
                top = " Results ",
                top_align = "center",
            },
        },
        buf_options = {
            modifiable = false,
            readonly = false,
        },
        win_options = {
            wrap = true,
            linebreak = true,
        },
    })
end

return ResultPopup
