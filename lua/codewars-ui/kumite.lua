local Description = require("codewars-ui.split.description")
local TestcaseSplit = require("codewars-ui.split.testcase")
local kstate = require("codewars.kumite.state")
local utils = require("codewars.utils")
local ui_utils = require("codewars-ui.utils")
local log = require("codewars.logger")
local api = vim.api

--- Kumite workspace (design §3.3). P1 mounts read-only `published_view`;
--- the editing states arrive with P2.
---@class cw.ui.Kumite
---@field snippet cw.KumiteSnippet
---@field state string one of codewars.kumite.state's states
---@field lang string
---@field bufnr integer?
---@field winid integer?
---@field description cw.ui.Description?
---@field fixture_split cw.ui.TestcaseSplit?
local Kumite = {}
Kumite.__index = Kumite

local INSERT_KEYS = { "i", "I", "a", "A", "o", "O", "c", "C", "s", "S", "R" }

---@return string
function Kumite:title()
    local dirty = "" -- P2: " +" when the model is dirty
    return ("Kumite · %s · %s · %s%s"):format(
        self.snippet.title, self.lang, kstate.label(self.state), dirty)
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
    if s.parent_id then
        local origin = s.forked_from_author and ("fork of a kumite by " .. s.forked_from_author)
            or ("fork of " .. s.parent_id)
        lines[#lines + 1] = origin
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("[Open on Codewars](https://www.codewars.com/kumite/%s)"):format(s.id)
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

    -- Unsupported-language fallback (eng D13): view always works; unknown
    -- languages render as plain text via the raw slug (no syntax defined).
    local lang_info = utils.get_lang(self.lang)
    local ft = lang_info and lang_info.ft or self.snippet.language

    ui_utils.buf_set_opts(self.bufnr, {
        buftype = "nofile",
        swapfile = false,
        buflisted = false,
        filetype = ft,
        modifiable = false,
    })

    local named = pcall(api.nvim_buf_set_name, self.bufnr, self:title())
    if not named then
        pcall(api.nvim_buf_set_name, self.bufnr, self:title() .. " #" .. self.snippet.id:sub(1, 6))
    end

    -- Read-only guard: insert-openers answer with the state machine's
    -- message instead of a bare E21.
    local _, edit_err = kstate.step(self.state, "edit")
    for _, key in ipairs(INSERT_KEYS) do
        vim.keymap.set("n", key, function()
            log.warn(edit_err)
        end, { buffer = self.bufnr, nowait = true })
    end
    vim.keymap.set("n", "g?", function()
        require("codewars.command").help()
    end, { buffer = self.bufnr })

    self.description = Description:new(self, function()
        return self:header_lines()
    end)
    self.description:mount()

    if self.snippet.fixture and self.snippet.fixture ~= "" then
        self.fixture_split = TestcaseSplit:new(self)
        self.fixture_split:mount()
        self.fixture_split:populate(self.snippet.fixture)
        ui_utils.buf_set_opts(self.fixture_split.bufnr, { modifiable = false })
    end

    if self.winid and api.nvim_win_is_valid(self.winid) then
        api.nvim_set_current_win(self.winid)
    end

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
end

function Kumite:_unmount()
    if vim.v.dying ~= 0 then
        return
    end

    -- P1 is read-only: nothing to lose on close. The P2 dirty-close guard
    -- (prompt + stash) hooks in here before any deletion happens.
    vim.schedule(function()
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
---@return cw.ui.Kumite
function Kumite:new(snippet)
    local obj = setmetatable({}, self)
    obj.snippet = snippet
    obj.lang = snippet.language
    obj.state = "published_view"
    return obj
end

return Kumite
