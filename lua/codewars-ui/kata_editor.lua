-- The nui-backed splits are required inside mount(), not here: everything
-- above mount (the model, dirty tracking, payload building) is pure, and
-- keeping it require-light lets it be exercised without a UI.
local kstate = require("codewars.kata.state")
local ui_utils = require("codewars-ui.utils")
local log = require("codewars.logger")
local api = vim.api

--- Kata authoring workspace (design KP2). Mirrors the kumite workspace, but a
--- kata has five text fields instead of two, so the main window is a PANE
--- SWITCHER: every field gets its own buffer, all live at once, and `g1`…`g5`
--- (or `:CW kata pane <name>`) swaps which one the window shows. Edits persist
--- in the hidden buffers, so switching panes never loses anything.
---
--- The side panel is read-only and always shows the kata metadata plus the
--- keys, since discipline/rank/tags have no natural buffer representation —
--- they are edited through `:CW kata meta`.
---@class cw.ui.KataEditor
---@field model cw.KataModel as loaded from the edit page
---@field cc table live code_challenge metadata (edited via :CW kata meta)
---@field saved table snapshot of what the server holds, for is_dirty()
---@field state string one of codewars.kata.state's states
---@field lang string
---@field pane string key of the pane currently displayed
---@field bufs table<string, integer>
---@field winid integer?
---@field bufnr integer? the buffer currently in the main window (console reads this)
---@field description cw.ui.Description?
---@field console cw.ui.Console?
local KataEditor = {}
KataEditor.__index = KataEditor

--- The editor's five text fields, in the order the website presents them.
--- `field` names the key inside `languages[lang]`; the description pane is the
--- odd one out and lives on `code_challenge` instead.
local PANES = {
    { key = "answer", label = "Complete Solution", field = "answer", kind = "code" },
    { key = "setup", label = "Initial Solution", field = "setup", kind = "code" },
    { key = "fixture", label = "Test Cases", field = "fixture", kind = "test" },
    { key = "example", label = "Example Test Cases", field = "example_fixture", kind = "test" },
    { key = "description", label = "Description", field = nil, kind = "markdown" },
}

local PANE_BY_KEY = {}
for i, pane in ipairs(PANES) do
    PANE_BY_KEY[pane.key] = vim.tbl_extend("force", pane, { index = i })
end

KataEditor.PANES = PANES

---@param key string
---@return table?
function KataEditor.pane_spec(key)
    return PANE_BY_KEY[key]
end

--- Live text of one pane, read from its buffer (falling back to the loaded
--- value while the workspace is still mounting).
---@param key string
---@return string
function KataEditor:pane_content(key)
    local bufnr = self.bufs and self.bufs[key]
    if bufnr and api.nvim_buf_is_valid(bufnr) then
        return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    end
    return self:loaded_value(key)
end

--- The value the server last gave us (or we last saved) for a pane.
---@param key string
---@return string
function KataEditor:loaded_value(key)
    local spec = PANE_BY_KEY[key]
    if not spec then
        return ""
    end
    if not spec.field then
        return self.cc.description or ""
    end
    local lm = self.model.languages[self.lang] or {}
    return lm[spec.field] or ""
end

---@return string test framework id for the current language
function KataEditor:test_framework()
    return (self.model.test_frameworks or {})[self.lang]
        or require("codewars.api.kumite").default_framework(self.lang)
end

--- Live edits: compare every pane and the metadata against the last-saved
--- snapshot rather than trusting a flag that pane switches could desync.
---@return boolean
function KataEditor:is_dirty()
    for _, pane in ipairs(PANES) do
        if self:pane_content(pane.key) ~= (self.saved.panes[pane.key] or "") then
            return true
        end
    end
    for _, key in ipairs({ "name", "category", "estimated_rank", "tags_text" }) do
        if (self.cc[key] or "") ~= (self.saved.cc[key] or "") then
            return true
        end
    end
    return (self.cc.coauthors_wanted == true) ~= (self.saved.cc.coauthors_wanted == true)
end

--- Snapshot the current content as "what the server holds" (on load, and
--- after every successful save).
function KataEditor:snapshot()
    local panes = {}
    for _, pane in ipairs(PANES) do
        panes[pane.key] = self:pane_content(pane.key)
    end
    self.saved = { panes = panes, cc = vim.deepcopy(self.cc) }
end

---@return string
function KataEditor:title()
    local dirty = self:is_dirty() and " +" or ""
    local name = self.cc.name ~= "" and self.cc.name or "(untitled kata)"
    return ("Kata · %s · %s · %s%s"):format(name, self.lang, kstate.label(self.state), dirty)
end

--- The workspace has no single title buffer (five panes share the window), so
--- the state/dirty marker lives in the info panel, which re-renders here.
function KataEditor:refresh_title()
    if self.description then
        self.description:populate()
    end
end

--- Human label for a category slug / rank value, for the info panel.
local function label_for(list, value)
    for _, entry in ipairs(list) do
        if entry.value == value then
            return entry.label
        end
    end
    return (value ~= nil and value ~= "") and value or "—"
end

---@return string[]
function KataEditor:header_lines()
    local kata_api = require("codewars.api.kata")
    local cc = self.cc
    local lines = {
        "# " .. (cc.name ~= "" and cc.name or "(untitled kata)"),
        "",
        ("**%s** · %s%s"):format(kstate.label(self.state), self.lang, self:is_dirty() and " · unsaved +" or ""),
        "",
        "## Kata",
        "- Discipline: " .. label_for(kata_api.CATEGORIES, cc.category),
        "- Estimated rank: " .. label_for(kata_api.RANKS, cc.estimated_rank),
        "- Tags: " .. (cc.tags_text ~= "" and cc.tags_text or "—"),
        "- Allow contributors: " .. (cc.coauthors_wanted and "yes" or "no"),
        "",
        ("[Open on Codewars](https://www.codewars.com/kata/%s)"):format(self.model.id),
        "",
        "## Panes",
    }
    for i, pane in ipairs(PANES) do
        local marker = pane.key == self.pane and "▸" or "·"
        lines[#lines + 1] = ("- %s `g%d` %s"):format(marker, i, pane.label)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Keys"
    for _, hint in ipairs({
        "`:CW kata meta` — edit name / discipline / rank / tags / contributors",
        "`:CW kata validate` — run the solution against the test cases",
        "`:CW kata save` — save the draft on codewars.com",
        self.state == "published" and "`:CW kata unpublish` — take it back to a draft"
            or "`:CW kata publish` — publish it (server re-runs your tests)",
        "`:CW kata delete` — delete this kata · `g?` — all commands",
    }) do
        lines[#lines + 1] = "- " .. hint
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
    local description = self:pane_content("description")
    if description ~= "" then
        for line in description:gmatch("[^\r\n]*") do
            lines[#lines + 1] = line
        end
    end
    return lines
end

--- Show a pane in the main window. The buffers all exist already, so this is
--- just a swap — `winfixbuf` is lifted for the duration so the window keeps
--- its protection against unrelated buffers the rest of the time.
---@param key string
function KataEditor:show_pane(key)
    local spec = PANE_BY_KEY[key]
    if not spec then
        local names = vim.tbl_map(function(p)
            return p.key
        end, PANES)
        return log.warn(("Unknown pane '%s' — try one of: %s"):format(tostring(key), table.concat(names, ", ")))
    end
    local bufnr = self.bufs[key]
    if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
        return log.error("That pane's buffer is gone — reopen the kata.")
    end
    if not (self.winid and api.nvim_win_is_valid(self.winid)) then
        return
    end

    local fixed = pcall(function()
        vim.wo[self.winid].winfixbuf = false
    end)
    api.nvim_win_set_buf(self.winid, bufnr)
    if fixed then
        pcall(function()
            vim.wo[self.winid].winfixbuf = true
        end)
    end

    self.pane = key
    self.bufnr = bufnr
    self:refresh_title()
    log.info(spec.label)
end

--- Cycle panes; `delta` of 1 is "next", -1 is "previous".
---@param delta integer
function KataEditor:cycle_pane(delta)
    local current = PANE_BY_KEY[self.pane] or PANE_BY_KEY.answer
    local next_index = ((current.index - 1 + delta) % #PANES) + 1
    self:show_pane(PANES[next_index].key)
end

function KataEditor:close()
    if self.winid and api.nvim_win_is_valid(self.winid) then
        pcall(api.nvim_win_close, self.winid, true)
    end
end

--- Build the `{ languages, language, code_challenge }` body for save/publish.
--- Every loaded language is re-sent (not just the edited one) so saving a
--- multi-language kata cannot drop the languages this workspace isn't showing;
--- the current language's fields come from the live buffers.
---@return table
function KataEditor:build_model()
    local languages = {}
    for lang, lm in pairs(self.model.languages) do
        languages[lang] = vim.deepcopy(lm)
    end
    local current = languages[self.lang] or {}
    current.answer = self:pane_content("answer")
    current.setup = self:pane_content("setup")
    current.fixture = self:pane_content("fixture")
    current.example_fixture = self:pane_content("example")
    languages[self.lang] = current

    local cc = vim.deepcopy(self.cc)
    cc.description = self:pane_content("description")

    return { language = self.lang, languages = languages, code_challenge = cc }
end

--- Adopt a just-saved body as the new baseline, so is_dirty() clears until the
--- next edit.
---@param model table the body we sent
function KataEditor:adopt(model)
    self.model.languages = model.languages
    self.cc = vim.deepcopy(model.code_challenge)
    self:snapshot()
end

--- Save the kata in place (`POST /kata/{id}`). Publication is unaffected, so
--- the state machine reverts to whichever state we came from.
function KataEditor:save()
    local _, err = kstate.step(self.state, "save")
    if err then
        return log.warn(err)
    end

    local prev = self.state
    self.state = "saving"
    self:refresh_title()

    local model = self:build_model()
    require("codewars.api.kata").save(self.model.id, model, function(serr)
        self.state = prev -- save_done and save_failed both REVERT
        if serr then
            if serr.auth then
                require("codewars.cache.cookie").delete()
            end
            self:refresh_title()
            return log.error("Kata save failed — " .. (serr.msg or "unknown error"))
        end
        self:adopt(model)
        self:refresh_title()
        log.info("Saved on codewars.com.")
    end)
end

--- Validate the solution against its own test cases (reuses the run path).
function KataEditor:validate()
    local _, err = kstate.step(self.state, "validate")
    if err then
        return log.warn(err)
    end
    if not self.console then
        return log.error("No console attached to this kata workspace.")
    end
    -- "test" is the console's run mode, not a kata action: it selects the
    -- "Running tests..." header. Without it the result popup clears blank.
    self.console:run("test")
end

--- Publish the kata (design KP1/KP2). Outward-facing and slow to undo, so it
--- confirms first and refuses to publish content the server has not seen.
function KataEditor:publish()
    local _, err = kstate.step(self.state, "publish")
    if err then
        return log.warn(err)
    end
    if self:is_dirty() then
        return log.warn("You have unsaved edits — :CW kata save before publishing.")
    end
    require("codewars-ui.popup.confirm").open({
        title = "Publish kata",
        message = ("Publish “%s” publicly on codewars.com?\n\nCodewars re-runs your tests server-side.")
            :format(self.cc.name),
        confirm = "Publish",
    }, function(confirmed)
        if not confirmed then
            return log.info("Publish cancelled.")
        end
        self:_do_publish()
    end)
end

function KataEditor:_do_publish()
    local prev = self.state
    self.state = "publishing"
    self:refresh_title()
    log.info("Publishing — Codewars runs your tests server-side, this can take a moment…")

    require("codewars.api.kata").publish(self.model.id, self:build_model(), function(url, perr)
        if perr then
            if perr.auth then
                require("codewars.cache.cookie").delete()
            end
            self.state = prev -- REVERT
            self:refresh_title()
            return log.error("Publish failed — " .. (perr.msg or "unknown error"))
        end
        self.state = kstate.step("publishing", "publish_done") -- "published"
        self.model.published = true
        self:refresh_title()
        log.info("Published! " .. url)
    end)
end

--- Un-publish (hide) a published kata. Reversible by publishing again.
function KataEditor:unpublish()
    local next_state, err = kstate.step(self.state, "unpublish")
    if err then
        return log.warn(err)
    end
    require("codewars.api.kata").unpublish(self.model.id, function(uerr)
        if uerr then
            if uerr.auth then
                require("codewars.cache.cookie").delete()
            end
            return log.error("Unpublish failed — " .. (uerr.msg or "unknown error"))
        end
        self.state = next_state -- "draft"
        self.model.published = false
        self:refresh_title()
        log.info("Unpublished — the kata is a draft again.")
    end)
end

--- Delete the kata. Irreversible, so it confirms with the kata's name and
--- closes the workspace on success.
function KataEditor:delete()
    local _, err = kstate.step(self.state, "delete")
    if err then
        return log.warn(err)
    end
    require("codewars-ui.popup.confirm").open({
        title = "Delete kata",
        message = ("Permanently delete “%s”?\n\nThis cannot be undone."):format(self.cc.name),
        confirm = "Delete",
    }, function(confirmed)
        if not confirmed then
            return log.info("Delete cancelled.")
        end
        require("codewars.api.kata").delete(self.model.id, function(derr)
            if derr then
                if derr.auth then
                    require("codewars.cache.cookie").delete()
                end
                -- Already gone: the goal is met, and keeping an editor open on
                -- a kata that no longer exists only invites a confusing save.
                if derr.gone then
                    log.warn(derr.msg)
                    self:snapshot()
                    return self:close()
                end
                return log.error("Delete failed — " .. (derr.msg or "unknown error"))
            end
            log.info("Kata deleted.")
            self:snapshot() -- the kata is gone; nothing to warn about on close
            self:close()
        end)
    end)
end

--- Edit the metadata that has no buffer of its own. KP3 replaces these
--- prompts with proper pickers; the field list and value mapping stay.
function KataEditor:edit_meta()
    local kata_api = require("codewars.api.kata")
    local choose = require("codewars-ui.popup.choose")

    -- Each row shows the field's CURRENT value, so the box doubles as a
    -- summary of what will be saved.
    local function current(key)
        local value = self.cc[key]
        return (value ~= nil and value ~= "") and value or "—"
    end
    local fields = {
        { key = "name", label = "Name: " .. current("name") },
        { key = "category", label = "Discipline: " .. label_for(kata_api.CATEGORIES, self.cc.category) },
        { key = "estimated_rank", label = "Estimated Rank: " .. label_for(kata_api.RANKS, self.cc.estimated_rank) },
        { key = "tags_text", label = "Tags: " .. current("tags_text") },
        {
            key = "coauthors_wanted",
            label = "Allow Contributors: " .. (self.cc.coauthors_wanted and "yes" or "no"),
        },
    }

    choose.open({ title = "Edit kata", items = fields }, function(field)
        if not field then
            return
        end
        if field.key == "name" then
            vim.ui.input({ prompt = "Kata name: ", default = self.cc.name }, function(value)
                if value then
                    self.cc.name = value
                    self:refresh_title()
                end
            end)
        elseif field.key == "tags_text" then
            vim.ui.input({ prompt = "Tags (comma separated): ", default = self.cc.tags_text }, function(value)
                if value then
                    self.cc.tags_text = value
                    self:refresh_title()
                end
            end)
        elseif field.key == "coauthors_wanted" then
            self.cc.coauthors_wanted = self.cc.coauthors_wanted ~= true
            self:refresh_title()
            log.info("Allow contributors: " .. (self.cc.coauthors_wanted and "yes" or "no"))
        else
            local is_discipline = field.key == "category"
            choose.open({
                title = is_discipline and "Discipline" or "Estimated Rank",
                items = is_discipline and kata_api.CATEGORIES or kata_api.RANKS,
            }, function(entry)
                if entry then
                    self.cc[field.key] = entry.value
                    self:refresh_title()
                end
            end)
        end
    end)
end

--- Jump to an already-open workspace for this kata, if any.
---@param id string
---@return boolean jumped
local function focus_existing(id)
    for _, ws in ipairs(_Cw_state.kata_editors or {}) do
        if ws.model.id == id and ws.winid and api.nvim_win_is_valid(ws.winid) then
            local ok, tabp = pcall(api.nvim_win_get_tabpage, ws.winid)
            if ok then
                pcall(api.nvim_set_current_tabpage, tabp)
                return true
            end
        end
    end
    return false
end

--- Filetype for a pane: the solution panes use the kata's language, the
--- fixture panes the language its tests are written in (they differ for
--- SQL/Solidity/BF), and the description is markdown.
---@param kind string
---@return string
function KataEditor:pane_filetype(kind)
    local filetypes = require("codewars.kumite.filetypes")
    if kind == "markdown" then
        return "markdown"
    end
    if kind == "test" then
        return filetypes.test(self.lang, nil) or ""
    end
    return filetypes.code(self.lang) or ""
end

function KataEditor:mount()
    if focus_existing(self.model.id) then
        return self
    end

    vim.cmd("$tabnew")
    self.winid = api.nvim_get_current_win()
    local scratch = api.nvim_get_current_buf()

    self.bufs = {}
    for _, pane in ipairs(PANES) do
        local bufnr = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(self:loaded_value(pane.key), "\n"))
        ui_utils.buf_set_opts(bufnr, {
            buftype = "acwrite", -- lets :w be intercepted without a real file
            swapfile = false,
            buflisted = false,
            filetype = self:pane_filetype(pane.kind),
            modifiable = true,
        })
        vim.bo[bufnr].modified = false
        pcall(api.nvim_buf_set_name, bufnr, ("Kata · %s · %s"):format(pane.label, self.model.id:sub(1, 6)))
        self.bufs[pane.key] = bufnr
    end

    api.nvim_win_set_buf(self.winid, self.bufs.answer)
    ui_utils.win_set_winfixbuf(self.winid)
    -- Drop the throwaway buffer $tabnew created; the panes replace it.
    if api.nvim_buf_is_valid(scratch) and scratch ~= self.bufs.answer then
        pcall(api.nvim_buf_delete, scratch, { force = true })
    end
    self.pane = "answer"
    self.bufnr = self.bufs.answer

    self:snapshot()

    for _, pane in ipairs(PANES) do
        local bufnr = self.bufs[pane.key]
        for i, target in ipairs(PANES) do
            vim.keymap.set("n", "g" .. i, function()
                self:show_pane(target.key)
            end, { buffer = bufnr, nowait = true, desc = "Kata pane: " .. target.label })
        end
        vim.keymap.set("n", "g?", function()
            require("codewars.command").help()
        end, { buffer = bufnr })
    end

    local Description = require("codewars-ui.split.description")
    self.description = Description:new(self, function()
        return self:header_lines()
    end)
    self.description:mount()

    if self.winid and api.nvim_win_is_valid(self.winid) then
        api.nvim_set_current_win(self.winid)
    end

    local Console = require("codewars-ui.layout.console")
    self.console = Console(self, function(_, result)
        require("codewars.kata.runner").run(self, result)
    end)

    _Cw_state.kata_editors = _Cw_state.kata_editors or {}
    table.insert(_Cw_state.kata_editors, self)

    self:autocmds()
    return self
end

function KataEditor:autocmds()
    local group = api.nvim_create_augroup("codewars_kata_" .. self.model.id, { clear = true })
    api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(self.winid),
        callback = function()
            self:_unmount()
        end,
    })

    for _, pane in ipairs(PANES) do
        local bufnr = self.bufs[pane.key]
        api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            group = group,
            buffer = bufnr,
            callback = function()
                self:refresh_title()
            end,
        })
        api.nvim_create_autocmd("BufWriteCmd", {
            group = group,
            buffer = bufnr,
            callback = function()
                vim.bo[bufnr].modified = false
                log.info("Kata panes live on codewars.com — :CW kata save to persist them.")
            end,
        })
    end
end

function KataEditor:_unmount()
    if vim.v.dying ~= 0 then
        return
    end

    -- No stash yet (KP3): make unsaved work impossible to lose silently by
    -- naming it loudly instead of closing quietly.
    if self:is_dirty() then
        log.warn("Closed with UNSAVED kata edits — they were not sent to codewars.com.")
    end

    vim.schedule(function()
        if self.console then
            self.console:unmount()
        end
        if self.description then
            self.description:unmount()
        end
        for _, bufnr in pairs(self.bufs or {}) do
            if api.nvim_buf_is_valid(bufnr) then
                api.nvim_buf_delete(bufnr, { force = true, unload = false })
            end
        end
        _Cw_state.kata_editors = vim.tbl_filter(function(ws)
            return ws.model.id ~= self.model.id
        end, _Cw_state.kata_editors or {})
    end)
end

---@param model cw.KataModel
---@return cw.ui.KataEditor
function KataEditor:new(model)
    local obj = setmetatable({}, self)
    obj.model = model
    obj.lang = model.language
    obj.cc = vim.deepcopy(model.code_challenge)
    obj.state = kstate.of(model.published)
    obj.pane = "answer"
    obj.saved = { panes = {}, cc = {} }
    return obj
end

return KataEditor
