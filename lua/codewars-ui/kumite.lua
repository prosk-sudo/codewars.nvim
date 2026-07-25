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
            "`:CW kumite save` — save as a draft on codewars.com",
            "`:CW kumite publish` — publish it publicly (after saving)",
            "`g?` — all commands · `:q` / `:q!` — close (unsaved edits are stashed)",
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
    log.info("Forked — edit the code/fixture, run :CW test, and :CW kumite save when ready.")
end

--- Save the workspace as a draft on codewars.com (design §2.4, P3). Create for
--- an unsaved local_new/local_fork (POST /kumite, adopting the returned id);
--- update for an existing server_draft (PUT /kumite/{id}). Branch on STATE, not
--- snippet.id — a fork's snippet.id is still the PARENT's id until first save.
function Kumite:save()
    local next_state, err = kstate.step(self.state, "save")
    if err then
        return log.warn(err)
    end

    local kumite_api = require("codewars.api.kumite")
    local prev = self.state
    local is_update = prev == "server_draft"
    self.state = next_state -- "saving"
    self:refresh_title()

    local model = {
        language = self.lang,
        language_version = self.snippet.language_version or kumite_api.default_version(self.lang),
        test_framework = self.snippet.test_framework,
        title = self.snippet.title,
        description = self.snippet.description,
        code = table.concat(api.nvim_buf_get_lines(self.bufnr, 0, -1, false), "\n"),
        fixture = self:fixture_content(),
        example_fixture = self.snippet.example_fixture,
        ["package"] = self.snippet["package"],
        parent_id = self.parent_id or self.snippet.parent_id,
        code_challenge_id = self.snippet.code_challenge_id,
        secret = self.snippet.secret,
    }
    local server_id = is_update and self.snippet.id or nil

    kumite_api.save_draft(server_id, model, function(res, serr)
        if serr then
            if serr.auth then
                require("codewars.cache.cookie").delete()
            end
            kstate.step("saving", "save_failed") -- REVERT: caller restores prev
            self.state = prev
            self:refresh_title()
            return log.error("Kumite save failed — " .. (serr.msg or "unknown error"))
        end

        self.state = kstate.step("saving", "save_done") -- "server_draft"
        -- Adopt the server draft id so later saves PUT; snapshot the saved
        -- content so is_dirty() clears until the next edit.
        self.snippet.id = res.id or self.snippet.id
        self.snippet.parent_id = self.parent_id or self.snippet.parent_id
        self.snippet.code = model.code
        self.snippet.fixture = model.fixture
        if self.description then
            self.description:populate() -- header now shows the Codewars link
        end
        self:refresh_title()
        pcall(api.nvim_buf_set_name, self.bufnr, self:title())
        log.info("Saved as a draft on codewars.com — :CW kumite open " .. self.snippet.id)
    end)
end

--- Publish the current kumite publicly (design §2.4, P3). Requires a saved,
--- non-dirty server draft and passing tests; confirms first because it is
--- public and cannot be casually undone.
function Kumite:publish()
    if self.state == "local_new" or self.state == "local_fork" then
        return log.warn("Save the kumite first (:CW kumite save), then publish.")
    end
    local _, err = kstate.step(self.state, "publish")
    if err then
        return log.warn(err)
    end
    if self:is_dirty() then
        return log.warn("You have unsaved edits — :CW kumite save before publishing.")
    end
    require("codewars-ui.popup.confirm").open({
        title = "Publish kumite",
        message = ("Publish “%s” publicly on codewars.com?"):format(self.snippet.title),
        confirm = "Publish",
    }, function(confirmed)
        if not confirmed then
            return log.info("Publish cancelled.")
        end
        self:_do_publish()
    end)
end

--- Run the saved code on the runner, then publish it (see kumite.publish).
function Kumite:_do_publish()
    self.state = "publishing"
    self:refresh_title()
    require("codewars.kumite.publish").run_and_publish({
        id = self.snippet.id,
        language = self.lang,
        code = table.concat(api.nvim_buf_get_lines(self.bufnr, 0, -1, false), "\n"),
        fixture = self:fixture_content(),
        test_framework = self.snippet.test_framework,
        language_version = self.snippet.language_version
            or require("codewars.api.kumite").default_version(self.lang),
        setup = self.snippet["package"] or "",
    }, function(url, err)
        if err then
            if err.auth then
                require("codewars.cache.cookie").delete()
            end
            self.state = "server_draft" -- REVERT
            self:refresh_title()
            return log.error("Publish failed — " .. (err.msg or "unknown error"))
        end
        self.state = kstate.step("publishing", "publish_done") -- "published"
        if self.description then
            self.description:populate()
        end
        self:refresh_title()
        pcall(api.nvim_buf_set_name, self.bufnr, self:title())
        log.info("Published! " .. url)
    end)
end

--- Unpublish (hide) this kumite (design §2.4, P3). Owner action; reversible by
--- publishing again. Only meaningful once it exists on codewars.com.
function Kumite:unpublish()
    local kumite_api = require("codewars.api.kumite")
    if not kumite_api.is_server_id(self.snippet.id) then
        return log.warn("This kumite isn't on codewars.com yet — nothing to unpublish.")
    end
    kumite_api.unpublish(self.snippet.id, function(err)
        if err then
            if err.auth then
                require("codewars.cache.cookie").delete()
            end
            return log.error("Unpublish failed — " .. (err.msg or "unknown error"))
        end
        if self.state == "published" then
            self.state = "server_draft"
            self:refresh_title()
            if self.description then
                self.description:populate()
            end
        end
        log.info("Unpublished — the kumite is hidden again (publish to re-list it).")
    end)
end

--- Convert this kumite into a new kata (design §2.4, P3). Creates a kata from
--- the kumite data and hides the kumite; confirms first. Reports the kata's
--- edit URL — finishing the kata (discipline/rank/description/publish) is done
--- on codewars.com for now.
function Kumite:convert()
    local kumite_api = require("codewars.api.kumite")
    if not kumite_api.is_server_id(self.snippet.id) then
        return log.warn("Save the kumite first (:CW kumite save), then convert.")
    end
    require("codewars-ui.popup.confirm").open({
        title = "Convert to kata",
        message = "Convert this kumite into a new kata?\n\nThis creates a kata and hides the kumite.",
        confirm = "Convert",
    }, function(confirmed)
        if not confirmed then
            return log.info("Convert cancelled.")
        end
        kumite_api.convert_to_kata(self.snippet.id, function(url, err)
            if err then
                if err.auth then
                    require("codewars.cache.cookie").delete()
                end
                return log.error("Convert failed — " .. (err.msg or "unknown error"))
            end
            if self.state == "published" then
                self.state = "server_draft" -- the kumite is hidden now
                self:refresh_title()
                if self.description then
                    self.description:populate()
                end
            end
            -- The response only carries the kata's edit URL, so dig the id out
            -- of it: the next step is `:CW kata open <id>`, and making the
            -- user parse an id out of a URL by eye is a poor handoff.
            local full = url:match("^https?://") and url or ("https://www.codewars.com" .. url)
            local kata_id = require("codewars.api.kata").parse_ref(full)
            if kata_id then
                log.info(("Converted to a new kata (%s) — open it with :CW kata open %s")
                    :format(kata_id, kata_id))
            else
                log.info("Converted to a new kata — finish authoring it at " .. full)
            end
        end)
    end)
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
            buftype = "acwrite", -- like the code buffer: intercept :w instead of E382 on nofile
            modifiable = kstate.is_editable(self.state),
            filetype = test_ft or "",
        })
        -- Populating marked it 'modified'; clear so a :w/:q on the fixture
        -- gives the same clean hint as the code buffer (no E382/E37).
        vim.bo[self.fixture_split.bufnr].modified = false
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
    -- :w in either editor is meaningless in P2 — steer to the real actions.
    local function write_hint(bufnr)
        vim.bo[bufnr].modified = false
        if kstate.is_editable(self.state) then
            log.info("Kumite runs locally — :CW test to run it. (Publishing arrives in a later update.)")
        else
            log.info("Read-only — :CW kumite fork to edit a copy.")
        end
    end

    -- Both the code buffer and (when present) the fixture split get the
    -- dirty-title marker and the :w hint, so editing either behaves the same.
    local editors = { self.bufnr }
    if self.fixture_split and self.fixture_split.bufnr then
        editors[#editors + 1] = self.fixture_split.bufnr
    end
    for _, bufnr in ipairs(editors) do
        -- Cosmetic dirty marker in the title; the guard itself recomputes.
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
                write_hint(bufnr)
            end,
        })
    end
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
