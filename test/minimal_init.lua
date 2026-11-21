-- Minimal init for running tests with plenary.nvim
-- Usage: nvim --headless -u test/minimal_init.lua -c "PlenaryBustedDirectory test/ {minimal_init = 'test/minimal_init.lua'}"

-- The plugin keeps the cookie, caches and kata stashes under
-- stdpath("cache") and solutions under stdpath("data"). Any spec that saved
-- something without redirecting storage itself wrote into the developer's
-- real ones (a run rewrote a kata stash in the real cache). Every spec
-- process gets its own throwaway root instead: stdpath() reads these on
-- each call, and tempname() lives under Neovim's own temp dir, which is
-- removed when the process exits. Set before anything loads the plugin,
-- whose storage defaults are computed when its config is first required.
local test_root = vim.fn.tempname()
vim.env.CW_TEST_ROOT = test_root
for _, kind in ipairs({ "CACHE", "DATA", "STATE" }) do
    local dir = test_root .. "/" .. kind:lower()
    vim.fn.mkdir(dir, "p")
    vim.env["XDG_" .. kind .. "_HOME"] = dir
end

local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
local nui_dir = os.getenv("NUI_DIR") or "/tmp/nui.nvim"

-- Same trap as the Makefile: test for the file we require, not the directory.
-- A stale /tmp entry can be an empty tree, which passes isdirectory() and
-- leaves plenary unresolvable.
-- PLENARY_DIR / NUI_DIR come from the environment and are about to be
-- deleted recursively. Refuse the paths where that would be catastrophic
-- rather than trusting whatever was exported: empty, root, $HOME, the
-- checkout itself, or any ANCESTOR of the checkout ("..", "../x"). The
-- Makefile applies the same rule; this copy covers running the init
-- directly without make.
local function safe_to_wipe(dir)
    if type(dir) ~= "string" or dir == "" then return false end
    local resolved = vim.fn.fnamemodify(dir, ":p"):gsub("/+$", "")
    if resolved == "" or resolved == "/" then return false end
    local home = (vim.loop.os_homedir() or ""):gsub("/+$", "")
    if home ~= "" and resolved == home then return false end
    local cwd = vim.fn.getcwd():gsub("/+$", "")
    -- cwd == resolved, or cwd lives underneath resolved (an ancestor)
    if (cwd .. "/"):sub(1, #resolved + 1) == resolved .. "/" then return false end
    -- resolved lives inside the checkout (PLENARY_DIR=lua)
    if (resolved .. "/"):sub(1, #cwd + 1) == cwd .. "/" then return false end
    return true
end

local function ensure_dep(dir, probe, repo, name)
    if vim.fn.filereadable(dir .. "/" .. probe) == 1 then return end
    if not safe_to_wipe(dir) then
        error(("refusing to delete %s=%s"):format(name, tostring(dir)))
    end
    vim.fn.delete(dir, "rf")
    vim.fn.system({ "git", "clone", repo, dir })
end

ensure_dep(plenary_dir, "lua/plenary/curl.lua", "https://github.com/nvim-lua/plenary.nvim", "PLENARY_DIR")
-- nui was never probed here, so running the init without `make deps`
-- failed on the first require("nui.split").
ensure_dep(nui_dir, "lua/nui/popup/init.lua", "https://github.com/MunifTanjim/nui.nvim", "NUI_DIR")

vim.opt.rtp:append(".")
vim.opt.rtp:append(plenary_dir)
vim.opt.rtp:append(nui_dir)

vim.cmd("runtime plugin/plenary.vim")
