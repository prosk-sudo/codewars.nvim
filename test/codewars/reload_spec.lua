-- A developer editing this plugin reloads it in a live session -- `:Lazy reload`,
-- or a lazy.nvim `config` that clears `package.loaded` before calling setup().
-- That re-runs setup() and re-executes every module body, so neither may assume
-- it is happening for the first time.
describe("reloading the plugin in a live session", function()
    local tmp = vim.fn.tempname()

    package.loaded["codewars.logger"] = {
        info = function() end,
        error = function() end,
        debug = function() end,
        warn = function() end,
    }

    it("keeps mounted UI reachable across a module-cache clear", function()
        require("codewars.config")
        _Cw_state.katas = { "mounted" }

        package.loaded["codewars.config"] = nil
        require("codewars.config")

        -- Dropping the handles here would strand the kata: its buffers, windows
        -- and augroups all outlive the reload, but nothing can reach them again.
        assert.same({ "mounted" }, _Cw_state.katas)
    end)

    it("registers the VimEnter hook once no matter how often setup runs", function()
        local codewars = require("codewars")
        local opts = { storage = { home = tmp, cache = tmp } }

        codewars.setup(opts)
        codewars.setup(opts)

        local hooks = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "codewars_setup" })
        assert.equals(1, #hooks)
    end)
end)
