-- :CW open hands the kata URL to the system opener. The slug comes from the
-- server, so it must only ever be a plain name (cmd.exe acts on & | ^ % even
-- inside one argv element, and vim.ui.open uses it too), and without
-- vim.ui.open (before 0.10) the URL must reach jobstart as one argv element,
-- never as text for a shell. That fallback
-- picks the opener from the system: cmd.exe on Windows (has("win32")), open on
-- macOS, xdg-open everywhere else, the BSDs included, and it starts nothing
-- when the opener is not installed.
describe(":CW open", function()
    local BASE = "https://www.codewars.com/kata/"
    local PLATFORMS = { "Darwin", "Linux", "Windows_NT" }

    local real_ui_open, real_jobstart, real_os_uname, real_has, real_executable
    local real_curr_kata, real_logger
    local utils, cmd, slug, started, opened, said, installed, probed

    -- Runs :CW open as `os_name`, with or without vim.ui.open, and records
    -- what reached the opener and what the user was told. Windows is what
    -- has("win32") says it is, so `win32` defaults to what a real Windows
    -- reports (sysname "Windows_NT") and can be set to split the two apart.
    local function open_on(os_name, has_ui_open, win32)
        if win32 == nil then
            win32 = os_name == "Windows_NT"
        end
        started, opened, said, probed = {}, {}, {}, {}
        vim.ui.open = has_ui_open and function(target)
            opened[#opened + 1] = target
        end or nil
        vim.loop.os_uname = function()
            return { sysname = os_name }
        end
        vim.fn.has = function(feature)
            if feature == "win32" then
                return win32 and 1 or 0
            end
            return real_has(feature)
        end
        cmd.open()
    end

    before_each(function()
        real_ui_open = vim.ui.open
        real_jobstart = vim.fn.jobstart
        real_os_uname = vim.loop.os_uname
        real_has = vim.fn.has
        real_executable = vim.fn.executable
        real_logger = package.loaded["codewars.logger"]
        slug = "multiply"
        started, opened, said, probed = {}, {}, {}, {}
        -- Every opener is installed unless a test takes one away.
        installed = { ["open"] = true, ["xdg-open"] = true, ["cmd.exe"] = true }

        vim.fn.executable = function(name)
            probed[#probed + 1] = name
            return installed[name] and 1 or 0
        end
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
        vim.fn.has = real_has
        vim.fn.executable = real_executable
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

        -- Everything that is neither Windows nor macOS is a Unix with
        -- xdg-open, not a Windows. These used to fall into the cmd.exe branch.
        for _, unix in ipairs({ "FreeBSD", "OpenBSD", "NetBSD", "DragonFly", "SunOS" }) do
            it("starts xdg-open on " .. unix .. ", not cmd.exe", function()
                open_on(unix, false)

                assert.are.equal(1, #started)
                assert.are.same({ "xdg-open", BASE .. "multiply" }, started[1].command)
                assert.is_true(started[1].opts.detach)
            end)
        end

        it("takes Windows from has('win32'), not from the sysname", function()
            open_on("MSYS_NT-10.0", false, true)

            assert.are.equal(1, #started)
            assert.are.same({ "cmd.exe", "/c", "start", "", BASE .. "multiply" }, started[1].command)
        end)

        it("does not take a Windows sysname for Windows when has('win32') says otherwise", function()
            open_on("Windows_NT", false, false)

            assert.are.equal(1, #started)
            assert.are.same({ "xdg-open", BASE .. "multiply" }, started[1].command)
        end)
    end)

    describe("when the opener is not installed", function()
        -- No job is started, and the user is told which opener is missing and
        -- given the URL, so they can open the kata by hand.
        local cases = {
            { label = "macOS", os_name = "Darwin", opener = "open" },
            { label = "Linux", os_name = "Linux", opener = "xdg-open" },
            { label = "FreeBSD", os_name = "FreeBSD", opener = "xdg-open" },
            { label = "Windows", os_name = "Windows_NT", opener = "cmd.exe" },
        }
        for _, case in ipairs(cases) do
            it("starts no job on " .. case.label .. " and names " .. case.opener .. " and the URL", function()
                installed[case.opener] = nil

                open_on(case.os_name, false)

                assert.are.equal(0, #started)
                assert.are.equal(1, #said)
                assert.are.equal("error", said[1].level)
                assert.is_truthy(said[1].msg:find(case.opener, 1, true), said[1].msg)
                assert.is_truthy(said[1].msg:find(BASE .. "multiply", 1, true), said[1].msg)
            end)
        end

        it("checks the opener it is about to start, and only that one", function()
            open_on("FreeBSD", false)

            assert.are.same({ "xdg-open" }, probed)
            assert.are.equal(1, #started)
            assert.are.equal(0, #said)
        end)

        it("does not say the opener is missing when it is there", function()
            open_on("Linux", false)

            assert.are.equal(0, #said)
        end)

        it("does not look for an opener when vim.ui.open does the work", function()
            installed["xdg-open"] = nil

            open_on("Linux", true)

            assert.are.same({ BASE .. "multiply" }, opened)
            assert.are.equal(0, #probed)
            assert.are.equal(0, #said)
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
        -- Every shape a real slug takes: a name, a name with digits, and the
        -- 24-hex id the site also accepts in the URL.
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
        -- Each of these is something cmd.exe or a POSIX shell would act on, or
        -- that would move the URL to another page. After the first two, each
        -- slug has exactly one character outside the allowed set, so allowing
        -- any one back makes exactly one of these fail.
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
