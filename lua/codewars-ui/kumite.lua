local Description = require("codewars-ui.split.description")
local TestcaseSplit = require("codewars-ui.split.testcase")
local Console = require("codewars-ui.layout.console")
local kstate = require("codewars.kumite.state")
local kstash = require("codewars.cache.kumite_stash")
local ui_utils = require("codewars-ui.utils")
local log = require("codewars.logger")
local api = vim.api

--- Kumite workspace (design §3.3). Opens read-only (`published_view`);
--- `:CW kumite fork` turns it into an editable `local_fork` you can run.
--- Editing/running is side-effect-free; saving/publishing arrive in P3.
---@class cw.ui.Kumite
---@field snippet cw.KumiteSnippet
---@field state string one of codewars.kumite.state's states
---@field parent_id string? set once forked
---@field lang string
---@field bufnr integer?
---@field winid integer?
---@field description cw.ui.Description?
---@field fixture_split cw.ui.TestcaseSplit?
---@field console cw.ui.Console?
local Kumite = {}
Kumite.__index = Kumite

local INSERT_KEYS = { "i", "I", "a", "A", "o", "O", "c", "C", "s", "S", "R" }

---@param id string?
---@return boolean # true for a real codewars snippet id (24 hex), false for a local one
local function is_server_id(id)
    return type(id) == "string" and id:match("^%x+$") ~= nil and #id == 24
end

--- The always-visible key legend shown at the top of the description panel,
--- adapted to the current state so users know what they can do right now.
---@return string[]
function Kumite:keys_hint()
    if kstate.is_editable(self.state) then
        return {
            "`:CW test` — run your code against the fixture",
            "`g?` — all commands · `:q` / `:q!` — close (unsaved edits are stashed)",
            "_(saving & publishing arrive in a later update)_",
        }
    end
    return {
        "`:CW kumite fork` — edit a local copy of this kumite",
        "`:CW test` — run it (after forking)",
        "`q` — close this view · `g?` — all commands",
    }
end

--- Live edits (T9): editable states diff their buffers against the loaded
--- snippet rather than trusting a cached "dirty" flag that split toggles
--- could desync.
---@return boolean
function Kumite:is_dirty()
    if not kstate.is_editable(self.state) then
        return false
    end
    local code = table.concat(api.nvim_buf_get_lines(self.bufnr, 0, -1, false), "\n")
    return code ~= (self.snippet.code or "") or self:fixture_content() ~= (self.snippet.fixture or "")
end

--- Live fixture text: the editable split when present, else the snippet's.
---@return string
function Kumite:fixture_content()
    if self.fixture_split then
        return self.fixture_split:content()
    end
    return self.snippet.fixture or ""
end

---@return string
function Kumite:title()
    local dirty = self:is_dirty() and " +" or ""
    return ("Kumite · %s · %s · %s%s"):format(
        self.snippet.title, self.lang, kstate.label(self.state), dirty)
end

--- Re-derive the buffer name from title (state or dirty flag changed).
function Kumite:refresh_title()
    if self.bufnr and api.nvim_buf_is_valid(self.bufnr) then
        pcall(api.nvim_buf_set_name, self.bufnr, self:title())
    end
end

---@return string[]
function Kumite:header_lines()
    local s = self.snippet
    local lines = {
        "# " .. s.title,
        "",
        ("**%s** · %s"):format(kstate.label(self.state), s.language),
    }
    local byline = {}
    if s.author then
        byline[#byline + 1] = "by " .. s.author
    end
    if s.published_at then
        byline[#byline + 1] = "published " .. (s.published_at:match("^(%d%d%d%d%-%d%d%-%d%d)") or s.published_at)
    end
    if #byline > 0 then
        lines[#lines + 1] = table.concat(byline, " · ")
    end
    local parent = self.parent_id or s.parent_id
    if parent then
        lines[#lines + 1] = s.forked_from_author and ("fork of a kumite by " .. s.forked_from_author)
            or ("fork of " .. parent)
    end
    lines[#lines + 1] = ""
    if is_server_id(s.id) then
        lines[#lines + 1] = ("[Open on Codewars](https://www.codewars.com/kumite/%s)"):format(s.id)
        lines[#lines + 1] = ""
    end

    -- Always-visible key legend so the panel is discoverable.
    lines[#lines + 1] = "## Keys"
    for _, hint in ipairs(self:keys_hint()) do
        lines[#lines + 1] = "- " .. hint
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
    if s.description and s.description ~= "" then
        for line in s.description:gmatch("[^\r\n]*") do
            lines[#lines + 1] = line
        end
    end
    return lines
end

--- Close the whole kumite workspace (its tab).
function Kumite:close()
    if self.winid and api.nvim_win_is_valid(self.winid) then
        pcall(api.nvim_win_close, self.winid, true)
    end
end

--- Apply the read-only insert-key guards for the current state. Cleared
--- when the workspace becomes editable (fork). Also binds `q` to close, so
--- a read-only view behaves like the other read-only panels.
function Kumite:apply_readonly_guard()
    local _, edit_err = kstate.step(self.state, "edit")
    for _, key in ipairs(INSERT_KEYS) do
        vim.keymap.set("n", key, function()
            log.warn(edit_err)
        end, { buffer = self.bufnr, nowait = true })
    end
    vim.keymap.set("n", "q", function()
        self:close()
    end, { buffer = self.bufnr, nowait = true })
end

function Kumite:clear_readonly_guard()
    for _, key in ipairs(INSERT_KEYS) do
        pcall(vim.keymap.del, "n", key, { buffer = self.bufnr })
    end
    -- Editing needs `q` back as the normal macro-record key.
    pcall(vim.keymap.del, "n", "q", { buffer = self.bufnr })
end

--- Fork this kumite into an editable local copy (design §3.4). Pure local
--- transition — nothing is created on codewars.com. A second fork of an
--- already-editable buffer is a no-op with a state-aware message.
function Kumite:fork()
    local next_state, err = kstate.step(self.state, "fork")
    if err then
        return log.warn(err)
    end

    self.parent_id = self.snippet.id
    self.state = next_state

    self:clear_readonly_guard()
    ui_utils.buf_set_opts(self.bufnr, { modifiable = true })
    if self.fixture_split and self.fixture_split.bufnr then
        ui_utils.buf_set_opts(self.fixture_split.bufnr, { modifiable = true })
    end

    if self.description then
        self.description:populate()
    end
    self:refresh_title()
    log.info("Forked — edit the code/fixture and run :CW test. (Saving arrives in a later update.)")
end

--- Jump to an already-open workspace for this snippet, if any.
---@param id string
---@return boolean jumped
local function focus_existing(id)
    for _, ws in ipairs(_Cw_state.kumite or {}) do
        if ws.snippet.id == id and ws.winid and api.nvim_win_is_valid(ws.winid) then
            local ok, tabp = pcall(api.nvim_win_get_tabpage, ws.winid)
            if ok then
                pcall(api.nvim_set_current_tabpage, tabp)
                return true
            end
        end
    end
    return false
end

function Kumite:mount()
    if focus_existing(self.snippet.id) then
        return self
    end

    vim.cmd("$tabnew")
    self.bufnr = api.nvim_get_current_buf()
    self.winid = api.nvim_get_current_win()
    ui_utils.win_set_winfixbuf(self.winid)

    api.nvim_buf_set_lines(self.bufnr, 0, -1, false, vim.split(self.snippet.code or "", "\n"))

    -- Syntax highlighting for every codewars language via the real Neovim
    -- filetype (not the file extension). Unknown/grammarless languages
    -- (eng D13) stay plain text.
    local ft = require("codewars.kumite.filetypes").code(self.lang) or ""

    ui_utils.buf_set_opts(self.bufnr, {
        buftype = "acwrite", -- lets :w be intercepted (fork/run hints) without a real file
        swapfile = false,
        buflisted = false,
        filetype = ft,
        modifiable = kstate.is_editable(self.state),
    })
    -- Populating an acwrite buffer marks it 'modified'; clear that so a
    -- freshly-opened kumite closes with :q (and `q`) without E37.
    vim.bo[self.bufnr].modified = false

    local named = pcall(api.nvim_buf_set_name, self.bufnr, self:title())
    if not named then
        pcall(api.nvim_buf_set_name, self.bufnr, self:title() .. " #" .. self.snippet.id:sub(1, 6))
    end

    if not kstate.is_editable(self.state) then
        self:apply_readonly_guard()
    end
    vim.keymap.set("n", "g?", function()
        require("codewars.command").help()
    end, { buffer = self.bufnr })

    self.description = Description:new(self, function()
        return self:header_lines()
    end)
    self.description:mount()

    -- A fixture split appears when the snippet ships one, or whenever the
    -- workspace is editable (so a fork/new has somewhere to write tests).
    if (self.snippet.fixture and self.snippet.fixture ~= "") or kstate.is_editable(self.state) then
        self.fixture_split = TestcaseSplit:new(self)
        self.fixture_split:mount()
        self.fixture_split:populate(self.snippet.fixture or "")
        -- The fixture is often a different language than the solution
        -- (BF/Solidity tests are JS, SQL tests are Ruby, …); override the
        -- split's extension-derived filetype with the real test filetype.
        local test_ft = require("codewars.kumite.filetypes").test(self.lang, self.snippet.test_language)
        ui_utils.buf_set_opts(self.fixture_split.bufnr, {
            modifiable = kstate.is_editable(self.state),
            filetype = test_ft or "",
        })
    end

    if self.winid and api.nvim_win_is_valid(self.winid) then
        api.nvim_set_current_win(self.winid)
    end

    self.console = Console(self, function(_, result)
        require("codewars.kumite.runner").run(self, result)
    end)

    _Cw_state.kumite = _Cw_state.kumite or {}
    table.insert(_Cw_state.kumite, self)

    self:autocmds()
    return self
end

function Kumite:autocmds()
    local group = api.nvim_create_augroup("codewars_kumite_" .. self.snippet.id, { clear = true })
    api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(self.winid),
        callback = function()
            self:_unmount()
        end,
    })
    -- Cosmetic dirty marker in the title; the guard itself recomputes.
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = group,
        buffer = self.bufnr,
        callback = function()
            self:refresh_title()
        end,
    })
    -- :w in the editor is meaningless in P2 — steer to the real actions.
    api.nvim_create_autocmd("BufWriteCmd", {
        group = group,
        buffer = self.bufnr,
        callback = function()
            vim.bo[self.bufnr].modified = false
            if kstate.is_editable(self.state) then
                log.info("Kumite runs locally — :CW test to run it. (Publishing arrives in a later update.)")
            else
                log.info("Read-only — :CW kumite fork to edit a copy.")
            end
        end,
    })
end

function Kumite:_unmount()
    if vim.v.dying ~= 0 then
        return
    end

    -- Safety net (eng D10): unsaved fork edits are stashed to the cache so a
    -- close never silently loses work. Recovery UI lands with My Drafts (P3);
    -- until then the stash file + this message are the guarantee.
    if self:is_dirty() then
        local path = kstash.save({
            id = self.snippet.id,
            title = self.snippet.title,
            language = self.lang,
            parent_id = self.parent_id or self.snippet.parent_id,
            code = table.concat(api.nvim_buf_get_lines(self.bufnr, 0, -1, false), "\n"),
            fixture = self:fixture_content(),
        })
        if path then
            log.info(("Unsaved kumite edits stashed to %s"):format(path))
        end
    end

    vim.schedule(function()
        if self.console then
            self.console:unmount()
        end
        if self.fixture_split then
            self.fixture_split:unmount()
        end
        if self.description then
            self.description:unmount()
        end
        if self.bufnr and api.nvim_buf_is_valid(self.bufnr) then
            api.nvim_buf_delete(self.bufnr, { force = true, unload = false })
        end
        _Cw_state.kumite = vim.tbl_filter(function(ws)
            return ws.bufnr ~= self.bufnr
        end, _Cw_state.kumite or {})
    end)
end

---@param snippet cw.KumiteSnippet
---@param opts? { state?: string } initial state (default published_view; New passes local_new)
---@return cw.ui.Kumite
function Kumite:new(snippet, opts)
    local obj = setmetatable({}, self)
    obj.snippet = snippet
    obj.lang = snippet.language
    obj.state = (opts and opts.state) or "published_view"
    return obj
end

return Kumite
