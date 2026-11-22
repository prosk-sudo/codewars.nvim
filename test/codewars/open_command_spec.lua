-- :CW open passes the kata URL to the system opener. The server-supplied slug
-- must be a plain name (cmd.exe acts on & | ^ % even in one argv element), and
-- without vim.ui.open (before 0.10) the URL must reach jobstart as one argv element.
describe(":CW open", function()
    local BASE = "https://www.codewars.com/kata/"
    local PLATFORMS = { "Darwin", "Linux", "Windows_NT" }

    local real_ui_open, real_jobstart, real_os_uname, real_curr_kata, real_logger
    local utils, cmd, slug, started, opened, said

    -- Runs :CW open as `os_name`; records what reached the opener and what the user saw.
    local function open_on(os_name, has_ui_open)
        started, opened, said = {}, {}, {}
        vim.ui.open = has_ui_open and function(target)
            opened[#opened + 1] = target
        end or nil
        vim.loop.os_uname = function()
            return { sysname = os_name }
        end
        cmd.open()
    end

    before_each(function()
        real_ui_open = vim.ui.open
        real_jobstart = vim.fn.jobstart
        real_os_uname = vim.loop.os_uname
        real_logger = package.loaded["codewars.logger"]
        slug = "multiply"
        started, opened, said = {}, {}, {}

        vim.fn.jobstart = function(command, opts)
            started[#started + 1] = { command = command, opts = opts }
            return 1
        end
        package.loaded["codewars.logger"] = setmetatable({}, {
            __index = function(_, level)
                return function(m) said[#said + 1] = { level = level, msg = tostring(m) } end
            end,
        })

        package.loaded["codewars.command"] = nil
        cmd = require("codewars.command")
        utils = require("codewars.utils")
        real_curr_kata = utils.curr_kata
        utils.curr_kata = function()
            return { slug = slug }
        end
    end)

    after_each(function()
        utils.curr_kata = real_curr_kata
        vim.ui.open = real_ui_open
        vim.fn.jobstart = real_jobstart
        vim.loop.os_uname = real_os_uname
        package.loaded["codewars.logger"] = real_logger
        package.loaded["codewars.command"] = nil
    end)

    describe("without vim.ui.open", function()
        it("starts open on macOS with the URL as its own argument, not shell text", function()
            open_on("Darwin", false)

            assert.are.equal(1, #started)
            assert.are.same({ "open", BASE .. "multiply" }, started[1].command)
            assert.is_true(started[1].opts.detach)
        end)

        it("starts xdg-open on Linux with the URL as its own argument, not shell text", function()
            open_on("Linux", false)

            assert.are.equal(1, #started)
            assert.are.same({ "xdg-open", BASE .. "multiply" }, started[1].command)
            assert.is_true(started[1].opts.detach)
        end)

        it("runs start through cmd.exe on Windows with the URL as its last argument, not shell text", function()
            open_on("Windows_NT", false)

            assert.are.equal(1, #started)
            assert.are.same({ "cmd.exe", "/c", "start", "", BASE .. "multiply" }, started[1].command)
            assert.is_true(started[1].opts.detach)
        end)
    end)

    describe("with vim.ui.open", function()
        it("hands the URL to vim.ui.open and starts nothing itself", function()
            open_on("Linux", true)

            assert.are.same({ BASE .. "multiply" }, opened)
            assert.are.equal(0, #started)
        end)
    end)

    describe("opening a kata", function()
        -- Every real slug shape: a name, a name with digits, the 24-hex id.
        for label, good in pairs({
            ["a hyphenated name"] = "fake-binary",
            ["digits in the name"] = "sum-of-2-lowest-numbers",
            ["an underscore"] = "snake_case-kata",
            ["a 24-hex id"] = "5266876b8f4bf2da9b000362",
            ["capital letters"] = "Unique-In-Order",
        }) do
            it("accepts a slug with " .. label .. " on every platform and opener", function()
                slug = good
                for _, os_name in ipairs(PLATFORMS) do
                    for _, has_ui_open in ipairs({ true, false }) do
                        open_on(os_name, has_ui_open)

                        local reached = has_ui_open and opened[1] or started[1].command[#started[1].command]
                        assert.are.equal(BASE .. good, reached)
                        assert.are.equal(0, #said)
                    end
                end
            end)
        end
    end)

    describe("a slug that is not a plain name", function()
        -- Things a shell would act on, or that move the URL elsewhere. After the
        -- first two, each has one bad character, so allowing it back fails one.
        for label, bad in pairs({
            ["a quote and a shell command"] = "x'; touch /tmp/pwned #",
            ["an ampersand and a program name"] = "x&calc.exe",
            ["an ampersand"] = "x&calc",
            ["a pipe"] = "x|calc",
            ["a semicolon"] = "x;calc",
            ["a single quote"] = "x'calc",
            ["a double quote"] = 'x"calc',
            ["a space"] = "x calc",
            ["a caret"] = "x^calc",
            ["a percent sign"] = "x%calc",
            ["a dollar sign"] = "x$calc",
            ["a backtick"] = "x`calc",
            ["a backslash"] = "x\\calc",
            ["a slash"] = "x/calc",
            ["a dot"] = "x.calc",
            ["a question mark"] = "x?calc",
            ["a hash"] = "x#calc",
            ["an angle bracket"] = "x>calc",
            ["a parenthesis"] = "x(calc",
            ["an exclamation mark"] = "x!calc",
            ["a newline"] = "x\ncalc",
            ["a tab"] = "x\tcalc",
            ["a non-ASCII letter"] = "caf\xc3\xa9",
            ["no characters at all"] = "",
        }) do
            it("is refused with " .. label .. " on every platform and opener", function()
                slug = bad
                for _, os_name in ipairs(PLATFORMS) do
                    for _, has_ui_open in ipairs({ true, false }) do
                        open_on(os_name, has_ui_open)

                        assert.are.equal(0, #started, os_name .. " started a job")
                        assert.are.equal(0, #opened, os_name .. " called vim.ui.open")
                        assert.are.equal(1, #said, os_name .. " did not say why")
                        assert.are.equal("error", said[1].level)
                    end
                end
            end)
        end

        it("is refused when the kata carries no slug", function()
            slug = nil

            for _, os_name in ipairs(PLATFORMS) do
                open_on(os_name, false)
                assert.are.equal(0, #started)
            end
            assert.are.equal("error", said[1].level)
        end)
    end)
end)
