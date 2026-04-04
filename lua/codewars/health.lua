local config = require("codewars.config")

local M = {}

local function ok(msg) vim.health.ok(msg) end
local function warn(msg) vim.health.warn(msg) end
local function error(msg) vim.health.error(msg) end
local function start(msg) vim.health.start(msg) end

function M.check()
    start("codewars.nvim")

    -- Neovim version
    if vim.fn.has("nvim-0.9.0") == 1 then
        local v = vim.version()
        ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
    else
        error("Neovim >= 0.9.0 required")
    end

    -- Dependencies
    start("Dependencies")

    local deps = {
        { mod = "plenary", name = "plenary.nvim", required = true },
        { mod = "nui.popup", name = "nui.nvim", required = true },
        { mod = "telescope", name = "telescope.nvim", required = true },
        { mod = "markdown", name = "markdown.nvim", required = false },
    }

    for _, dep in ipairs(deps) do
        local dep_ok = pcall(require, dep.mod)
        if dep_ok then
            ok(dep.name .. " loaded")
        elseif dep.required then
            error(dep.name .. " not found (required)")
        else
            warn(dep.name .. " not found (optional)")
        end
    end

    -- Treesitter markdown parser
    local has_md_parser = pcall(vim.treesitter.language.inspect, "markdown")
    if has_md_parser then
        ok("Treesitter markdown parser installed")
    else
        warn("Treesitter markdown parser not installed (run :TSInstall markdown for description rendering)")
    end

    -- Authentication
    start("Authentication")

    local cookie = require("codewars.cache.cookie")
    local c = cookie.get()
    if c then
        ok("Cookie file exists")
        ok("CSRF-TOKEN present")
        ok("_session_id present")

        -- Try to validate session
        local user_api = require("codewars.api.user")
        local done = false

        user_api.get_current(function(profile, err)
            if not err and profile and profile.username then
                ok(("Session valid (username: %s)"):format(profile.username))
            else
                warn("Session may be expired. Run :CW cookie to re-authenticate.")
            end
            done = true
        end)

        -- Wait briefly for async response
        vim.wait(3000, function() return done end, 100)
        if not done then
            warn("Could not validate session (timeout). Codewars may be unreachable.")
        end
    else
        local cache_path = config.storage.cache
            and config.storage.cache:joinpath("cookie"):absolute()
            or "~/.cache/nvim/codewars/cookie"
        error(("No cookie file found at %s. Run :CW cookie to sign in."):format(cache_path))
    end

    -- Configuration
    start("Configuration")

    local lang_source = config.lang_persisted and "persisted" or "config/auto-detected"
    ok(("Default language: %s (%s)"):format(config.lang, lang_source))
    ok(("Username: %s"):format(config.user.username ~= "" and config.user.username or "(not yet detected)"))
    ok(("Storage: %s"):format(config.storage.home and config.storage.home:absolute() or "not set"))
    ok(("Cache: %s"):format(config.storage.cache and config.storage.cache:absolute() or "not set"))

    -- Problem list cache
    start("Cache")

    local problemlist = require("codewars.cache.problemlist")
    local items = problemlist.get()
    if items then
        ok(("%d kata cached"):format(#items))
    else
        warn("Problem list cache is empty or expired. Run :CW cache update to populate.")
    end

    local session_dir = config.storage.cache and config.storage.cache:joinpath("sessions")
    if session_dir and session_dir:exists() then
        local count = 0
        local scan = vim.loop.fs_scandir(session_dir:absolute())
        if scan then
            while vim.loop.fs_scandir_next(scan) do count = count + 1 end
        end
        ok(("%d session cache files"):format(count))
    else
        ok("No session cache files")
    end

    local completed_cache = require("codewars.cache.completed")
    local completed, is_stale = completed_cache.get()
    if #completed > 0 then
        local stale_str = is_stale and " (stale)" or ""
        ok(("%d completed kata cached%s"):format(#completed, stale_str))
    else
        ok("No completed kata cached")
    end
end

return M
