-- Minimal init for running tests with plenary.nvim
-- Usage: nvim --headless -u test/minimal_init.lua -c "PlenaryBustedDirectory test/ {minimal_init = 'test/minimal_init.lua'}"

local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
local nui_dir = os.getenv("NUI_DIR") or "/tmp/nui.nvim"

-- Same trap as the Makefile: test for the file we require, not the directory.
-- A stale /tmp entry can be an empty tree, which passes isdirectory() and
-- leaves plenary unresolvable.
if vim.fn.filereadable(plenary_dir .. "/lua/plenary/curl.lua") == 0 then
    vim.fn.delete(plenary_dir, "rf")
    vim.fn.system({ "git", "clone", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end

vim.opt.rtp:append(".")
vim.opt.rtp:append(plenary_dir)
vim.opt.rtp:append(nui_dir)

vim.cmd("runtime plugin/plenary.vim")
