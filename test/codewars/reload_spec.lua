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

    -- `_Cw_state or {}` adopted whatever was already there. A table written by
    -- an older version -- or any table missing a field this one added -- came
    -- through without `katas`, which utils.kata_tabs and codewars.stop index
    -- unguarded. The reload the branch exists to make safe is exactly when a
    -- table from a different version is what you find.
    it("fills in state a previous version never wrote", function()
        _Cw_state = { menu = "kept" }

        package.loaded["codewars.config"] = nil
        require("codewars.config")

        assert.are.same({}, _Cw_state.katas, "katas must exist after a reload")
        assert.are.equal("kept", _Cw_state.menu, "existing fields must survive")

        assert.has_no.errors(function()
            require("codewars.utils").kata_tabs()
        end)
    end)

    -- Menu._active lives on the module table, so a reload clears it while
    -- _Cw_state.menu -- the same object -- survives. refresh_stats returned
    -- early on the nil, and the dashboard's completed count then never moved
    -- again for the rest of the session, with nothing said.
    it("still refreshes the dashboard after a reload clears the module", function()
        -- Asserted through the API call rather than the stats field: the field
        -- differs between branches, reaching the network at all does not.
        local reached = 0
        package.loaded["codewars.api.user"] = {
            get = function(_, cb) reached = reached + 1 ; cb(nil, { msg = "stub" }) end,
            get_current = function(cb) reached = reached + 1 ; cb(nil, { msg = "stub" }) end,
        }
        package.loaded["codewars-ui.renderer.menu"] = nil
        local Menu = require("codewars-ui.renderer.menu")

        _Cw_state = _Cw_state or {}
        _Cw_state.menu = { bufnr = nil }
        Menu._active = nil -- what a reload leaves behind

        Menu.refresh_stats()
        vim.wait(50, function() return false end)
        package.loaded["codewars.api.user"] = nil

        assert.is_true(reached > 0,
            "refresh_stats gave up instead of finding the menu in _Cw_state")
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
