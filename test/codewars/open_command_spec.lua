-- :CW open on a Neovim without vim.ui.open (before 0.10) hands the kata URL
-- to the system opener through jobstart. The URL embeds the kata slug, which
-- comes from the server, so it must travel as one argv element: a string
-- would go through the shell, and a slug with a quote in it would run
-- whatever followed.
describe(":CW open without vim.ui.open", function()
    local MALICIOUS_SLUG = "x'; touch /tmp/pwned #"
    local MALICIOUS_URL = "https://www.codewars.com/kata/" .. MALICIOUS_SLUG

    local real_ui_open, real_jobstart, real_os_uname, real_curr_kata
    local utils, cmd, started

    local function open_on(os_name)
        vim.loop.os_uname = function()
            return { sysname = os_name }
        end
        cmd.open()
    end

    before_each(function()
        real_ui_open = vim.ui.open
        real_jobstart = vim.fn.jobstart
        real_os_uname = vim.loop.os_uname
        started = {}

        vim.ui.open = nil
        vim.fn.jobstart = function(command, opts)
            started[#started + 1] = { command = command, opts = opts }
            return 1
        end

        package.loaded["codewars.command"] = nil
        cmd = require("codewars.command")
        utils = require("codewars.utils")
        real_curr_kata = utils.curr_kata
        utils.curr_kata = function()
            return { slug = MALICIOUS_SLUG }
        end
    end)

    after_each(function()
        utils.curr_kata = real_curr_kata
        vim.ui.open = real_ui_open
        vim.fn.jobstart = real_jobstart
        vim.loop.os_uname = real_os_uname
        package.loaded["codewars.command"] = nil
    end)

    it("starts open on macOS with the URL as its own argument, not shell text", function()
        open_on("Darwin")

        assert.are.equal(1, #started)
        assert.are.same({ "open", MALICIOUS_URL }, started[1].command)
        assert.is_true(started[1].opts.detach)
    end)

    it("starts xdg-open on Linux with the URL as its own argument, not shell text", function()
        open_on("Linux")

        assert.are.equal(1, #started)
        assert.are.same({ "xdg-open", MALICIOUS_URL }, started[1].command)
        assert.is_true(started[1].opts.detach)
    end)

    it("starts the Windows opener with the URL as its last argument, not shell text", function()
        open_on("Windows_NT")

        assert.are.equal(1, #started)
        assert.are.equal("table", type(started[1].command))
        assert.are.equal(MALICIOUS_URL, started[1].command[#started[1].command])
        assert.is_true(started[1].opts.detach)
    end)

    it("leaves the URL alone when vim.ui.open exists", function()
        local opened = {}
        vim.ui.open = function(target)
            opened[#opened + 1] = target
        end

        open_on("Linux")

        assert.are.same({ MALICIOUS_URL }, opened)
        assert.are.equal(0, #started)
    end)
end)
