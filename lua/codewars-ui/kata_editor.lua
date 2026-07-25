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

--- The per-language code fields, in payload terms. Derived from PANES so the
--- list cannot drift from the panes that carry it.
local LANG_FIELDS = {}
for _, pane in ipairs(PANES) do
    if pane.field then
        LANG_FIELDS[#LANG_FIELDS + 1] = pane.field
    end
end

local PANE_BY_KEY = {}
for i, pane in ipairs(PANES) do
    PANE_BY_KEY[pane.key] = vim.tbl_extend("force", pane, { index = i })
end

KataEditor.PANES = PANES

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
        or require("codewars.languages.runtimes").default_framework(self.lang)
end

--- Runtimes the editor offers for a language, as `{id, label, default}` rows.
---@param lang string?
---@return table[]
function KataEditor:runtimes(lang)
    local info = (self.model.version_info or {})[lang or self.lang]
    return type(info) == "table" and info or {}
end

--- The runtime version this workspace will submit for a language: whatever the
--- user picked, else the runtime the editor marks `default:true`, else the
--- language's shared fallback.
---@param lang string?
---@return string
function KataEditor:version(lang)
    lang = lang or self.lang
    if self.versions[lang] then
        return self.versions[lang]
    end
    for _, runtime in ipairs(self:runtimes(lang)) do
        if runtime.default == true then
            return runtime.id
        end
    end
    return require("codewars.api.kata").default_version(lang) or ""
end

---@param lang string
---@param id string
function KataEditor:set_version(lang, id)
    self.versions[lang] = id
end

--- Languages you can switch to: the ones this kata already has (marked), then
--- every other runtime the editor offers. Picking an unused one ADDS it — the
--- save payload sends an empty `id` for a language being added, which is the
--- documented way to create one.
---@return { label: string, lang: string, existing: boolean }[]
function KataEditor:available_languages()
    local existing, rows = {}, {}
    for lang in pairs(self.model.languages or {}) do
        existing[lang] = true
    end
    local names = vim.tbl_keys(existing)
    table.sort(names)
    for _, lang in ipairs(names) do
        local marker = lang == self.lang and "▸ " or "  "
        rows[#rows + 1] = { label = marker .. lang .. " (in this kata)", lang = lang, existing = true }
    end

    local others = {}
    for lang in pairs(self.model.version_info or {}) do
        if not existing[lang] then
            others[#others + 1] = lang
        end
    end
    table.sort(others)
    for _, lang in ipairs(others) do
        rows[#rows + 1] = { label = "  " .. lang .. " — add to this kata", lang = lang, existing = false }
    end
    return rows
end

--- Show another language's code in the panes. Buffer contents for the language
--- being left are written back into the model first, so switching away and
--- back never loses work.
---@param lang string
function KataEditor:switch_language(lang)
    -- Ask the state machine BEFORE touching anything: during saving/publishing
    -- the panes are locked, and rewriting them would throw after self.lang had
    -- already moved, leaving the buffers and the model disagreeing.
    local _, err = kstate.step(self.state, "edit")
    if err then
        return log.warn(err)
    end
    if lang == self.lang then
        return log.info("Already editing " .. lang .. ".")
    end

    local languages = self.model.languages or {}
    languages[self.lang] = self:pane_fields_into(languages[self.lang] or {})

    -- Adding a language: an empty entry with no snippet id, which is what the
    -- save contract expects for one that does not exist server-side yet.
    -- Test Cases are seeded from the language's starter fixture (the same
    -- template :CW kumite new uses) rather than left blank — an empty fixture
    -- buffer gives you nothing to write against, and Codewars rejects a
    -- publish without tests anyway. Unknown languages yield "", so this is
    -- safe for every one of the ~58 the editor offers.
    local added = languages[lang] == nil
    if added then
        languages[lang] = {
            id = "",
            name = lang,
            answer = "",
            setup = "",
            fixture = require("codewars.languages.fixtures").get(lang) or "",
            example_fixture = "",
            ["package"] = "",
        }
    end
    self.model.languages = languages
    self.lang = lang

    for _, pane in ipairs(PANES) do
        local bufnr = self.bufs and self.bufs[pane.key]
        if bufnr and api.nvim_buf_is_valid(bufnr) and pane.field then
            api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(self:loaded_value(pane.key), "\n"))
            ui_utils.buf_set_opts(bufnr, { filetype = self:pane_filetype(pane.kind) })
            vim.bo[bufnr].modified = false
        end
    end

    self:refresh_title()
    log.info(added
        and ("Added %s — write its solution and tests, then :CW kata save."):format(lang)
        or ("Editing %s (%s)."):format(lang, self:version()))
end

--- Pick the language to edit (or add one). Routed through the same icon
--- dropdown `:CW train` uses, so language selection looks identical wherever
--- you meet it.
function KataEditor:choose_language()
    local existing, offered = {}, {}
    for _, row in ipairs(self:available_languages()) do
        offered[row.lang] = true
        if row.existing then
            existing[row.lang] = true
        end
    end
    require("codewars.picker").kata_language({
        current = self.lang,
        existing = existing,
        offered = offered,
    }, function(slug)
        self:switch_language(slug)
    end)
end

--- Pick the runtime version submitted for the current language.
function KataEditor:choose_version()
    local runtimes = self:runtimes()
    if #runtimes == 0 then
        return log.warn(("Codewars lists no runtimes for %s — the language default is used.")
            :format(self.lang))
    end
    local current = self:version()
    local items = {}
    for _, runtime in ipairs(runtimes) do
        local marker = runtime.id == current and "▸ " or "  "
        local note = runtime.default == true and " (default)" or ""
        items[#items + 1] = { label = marker .. (runtime.label or runtime.id) .. note, id = runtime.id }
    end
    require("codewars-ui.popup.choose").open({
        title = self.lang .. " runtime",
        items = items,
    }, function(item)
        if item then
            self:set_version(self.lang, item.id)
            self:refresh_title()
            log.info(("%s runtime: %s"):format(self.lang, item.id))
        end
    end)
end

--- Live edits: compare every pane and the metadata against the last-saved
--- snapshot rather than trusting a flag that pane switches could desync.
---@return boolean
function KataEditor:is_dirty()
    local saved = self.saved or {}
    local saved_langs = saved.languages or {}

    -- visible language: compare the live buffers
    local current = self:pane_fields_into({})
    local base = saved_langs[self.lang] or {}
    for _, field in ipairs(LANG_FIELDS) do
        if (current[field] or "") ~= (base[field] or "") then
            return true
        end
    end

    -- hidden languages: their edits live in the model after a switch
    for lang, lm in pairs(self.model.languages or {}) do
        if lang ~= self.lang then
            local other = saved_langs[lang]
            if not other then
                return true -- a language added since the last save
            end
            for _, field in ipairs(LANG_FIELDS) do
                if (lm[field] or "") ~= (other[field] or "") then
                    return true
                end
            end
        end
    end

    if self:pane_content("description") ~= (saved.description or "") then
        return true
    end
    for _, key in ipairs({ "name", "category", "estimated_rank", "tags_text" }) do
        if (self.cc[key] or "") ~= ((saved.cc or {})[key] or "") then
            return true
        end
    end
    if (self.cc.coauthors_wanted == true) ~= ((saved.cc or {}).coauthors_wanted == true) then
        return true
    end
    -- the chosen runtime is part of the payload; without this a picked version
    -- was silently discarded on close
    for lang, version in pairs(self.versions or {}) do
        if version ~= (saved.versions or {})[lang] then
            return true
        end
    end
    return false
end

--- Copy the four code panes' live text into a `languages[lang]` entry. Both
--- the save payload and a language switch need exactly this; keeping the
--- field list in one place stops the two from drifting apart.
---@param entry table
---@return table entry
function KataEditor:pane_fields_into(entry)
    for _, pane in ipairs(PANES) do
        if pane.field then
            entry[pane.field] = self:pane_content(pane.key)
        end
    end
    return entry
end

--- Snapshot the current content as "what the server holds" (on load, and
--- after every successful save).
--- Build the saved baseline from a languages table plus metadata.
---@param languages table<string, table>
---@param cc table
---@param description string
local function baseline(languages, cc, description, versions)
    local langs = {}
    for lang, lm in pairs(languages or {}) do
        langs[lang] = {}
        for _, field in ipairs(LANG_FIELDS) do
            langs[lang][field] = lm[field] or ""
        end
    end
    return {
        languages = langs,
        description = description or "",
        cc = vim.deepcopy(cc or {}),
        versions = vim.deepcopy(versions or {}),
    }
end

--- Snapshot the current content as "what the server holds".
---
--- The baseline is PER LANGUAGE. One flat snapshot could not tell a real edit
--- from a language switch: after switching, the buffers legitimately differ
--- from the previous language's snapshot (false dirty), and switching back
--- could read as clean while a hidden language still held unsaved edits.
function KataEditor:snapshot()
    local languages = {}
    for lang, lm in pairs(self.model.languages or {}) do
        languages[lang] = lm
    end
    -- the visible language's truth is its buffers, not the model copy
    languages[self.lang] = self:pane_fields_into({})
    self.saved = baseline(languages, self.cc, self:pane_content("description"), self.versions)
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
    ui_utils.debounce_cancel(self, "refresh")
    if self.description then
        self.description:populate()
    end
end

--- Debounced refresh for the typing path.
---
--- Rendering the panel runs is_dirty(), which diffs every pane's full text
--- against the saved snapshot — correct, and deliberately not a flag (a flag
--- desyncs on pane switches), but far too much work per keystroke. Coalescing
--- into one refresh per idle moment keeps the diff authoritative while the
--- cost stops scaling with typing speed.
local REFRESH_DEBOUNCE_MS = 150

function KataEditor:refresh_title_soon()
    ui_utils.debounce(self, "refresh", REFRESH_DEBOUNCE_MS, function()
        self:refresh_title()
    end)
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
        ("**%s** · %s %s%s"):format(
            kstate.label(self.state), self.lang, self:version(),
            self:is_dirty() and " · unsaved +" or ""),
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
    languages[self.lang] = self:pane_fields_into(languages[self.lang] or {})

    -- Every language carries the runtime it will run on. Without this a
    -- language the user re-versioned would silently save on the old runtime.
    for lang, lm in pairs(languages) do
        lm.default_version = self:version(lang)
    end

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

    -- Baseline comes from the payload that was SENT, never from the live
    -- buffers. Reading buffers here marked anything typed while the request
    -- was in flight as "saved" even though the server never received it, and
    -- closing afterwards then dropped it silently.
    self.saved = baseline(model.languages, model.code_challenge,
        model.code_challenge.description, self.versions)
end

--- Lock or unlock every pane. Panes are locked while a save/publish is in
--- flight (the states codewars.kata.state marks `locked`), so the buffers
--- cannot drift from the payload already on its way to the server.
---@param locked boolean
function KataEditor:set_panes_locked(locked)
    ui_utils.set_bufs_modifiable(vim.tbl_values(self.bufs or {}), locked)
end

--- Change state and re-apply the lock in one step. Pairing these by hand at
--- every transition meant a future one could silently leave the panes
--- writable during an in-flight request.
---@param next_state string
function KataEditor:set_state(next_state)
    self.state = next_state
    self:set_panes_locked(kstate.is_locked(next_state))
end

--- Codewars requires a kata name to be free. The rejection names the field and
--- the reason, and the name travels inside the same payload, so a rename can be
--- applied and the request retried immediately -- no intermediate save, unlike
--- the kumite path where convert reads the STORED title.
---@param what string "save" or "publish", for the prompt
---@param retry fun() re-issues the request that was rejected
function KataEditor:_rename_and_retry(what, retry)
    log.warn("Codewars already has a kata with this name — pick another.")
    vim.ui.input({
        prompt = "New kata name: ",
        default = self.cc.name or "",
    }, function(name)
        if not name or vim.trim(name) == "" then
            return log.info(("%s cancelled — the name is still taken."):format(what))
        end
        self.cc.name = vim.trim(name)
        self:refresh_title()
        retry()
    end)
end

--- Save the kata in place (`POST /kata/{id}`). Publication is unaffected, so
--- the state machine reverts to whichever state we came from.
function KataEditor:save()
    local _, err = kstate.step(self.state, "save")
    if err then
        return log.warn(err)
    end

    local prev = self.state
    self:set_state("saving")
    self:refresh_title()

    local model = self:build_model()
    require("codewars.api.kata").save(self.model.id, model, function(serr)
        self:set_state(prev) -- save_done and save_failed both REVERT
        if serr then
            if serr.auth then
                require("codewars.cache.cookie").delete()
            end
            self:refresh_title()
            if require("codewars.api.errors").is_name_taken(serr) then
                return self:_rename_and_retry("Save", function() self:save() end)
            end
            return log.error("Kata save failed — " .. (serr.msg or "unknown error"))
        end
        self:adopt(model)
        self:refresh_title()
        log.info("Saved on codewars.com.")

        -- A language created by this save was sent with an empty snippet id.
        -- The response is a Turbolinks re-render, not JSON, so the new id is
        -- only learnable by re-reading the edit page. Without this every later
        -- save presents the language as new again and re-creates it.
        for _, lm in pairs(model.languages or {}) do
            if lm.id == nil or lm.id == "" then
                self:refresh_language_ids()
                break
            end
        end
    end)
end

--- Re-read the edit page to pick up snippet ids the server just minted for
--- languages this workspace added. Content is untouched; only ids are adopted.
function KataEditor:refresh_language_ids()
    require("codewars.api.kata").load(self.model.id, self.lang, function(fresh, err)
        if err or not fresh then
            return log.warn("Saved — but could not read back the new language's id. "
                .. "Reopen the kata before saving again, or it will be created twice.")
        end
        for lang, lm in pairs(fresh.languages or {}) do
            local mine = (self.model.languages or {})[lang]
            if mine and (mine.id == nil or mine.id == "") then
                mine.id = lm.id or ""
            end
        end
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
    self:set_state("publishing")
    self:refresh_title()
    log.info("Publishing — Codewars runs your tests server-side, this can take a moment…")

    local model = self:build_model()
    self._publish_token = { live = true }
    require("codewars.api.kata").publish(self.model.id, model, function(url, perr)
        if perr then
            if perr.auth then
                require("codewars.cache.cookie").delete()
            end
            self:set_state(prev) -- REVERT
            self:refresh_title()
            if require("codewars.api.errors").is_name_taken(perr) then
                -- retry _do_publish, not publish(): the user already confirmed,
                -- and the rename legitimately makes the workspace dirty.
                return self:_rename_and_retry("Publish", function() self:_do_publish() end)
            end
            return log.error("Publish failed — " .. (perr.msg or "unknown error"))
        end
        self:set_state(kstate.step("publishing", "publish_done")) -- "published"
        self.model.published = true
        -- Publish persists the same body a save would, so the baseline moves
        -- with it; without this the workspace still looks dirty afterwards.
        self:adopt(model)
        self:refresh_title()
        log.info("Published! " .. url)
    end, self._publish_token)
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
        self:set_state(next_state) -- "draft"
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
    -- Without this, metadata typed during an in-flight save is overwritten when
    -- adopt() installs the payload that was already sent.
    local _, blocked = kstate.step(self.state, "edit")
    if blocked then
        return log.warn(blocked)
    end
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
    -- Language and runtime deliberately absent: they have their own commands
    -- (:CW kata lang / :CW kata version) and their own pickers.

    -- Editing one field almost always means editing another, so the panel
    -- REOPENS after each change (with the new value already shown) instead of
    -- making the user re-run the command five times. `q`/`Esc` closes it.
    local function reopen()
        vim.schedule(function()
            self:edit_meta()
        end)
    end

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
                reopen()
            end)
        elseif field.key == "tags_text" then
            vim.ui.input({ prompt = "Tags (comma separated): ", default = self.cc.tags_text }, function(value)
                if value then
                    self.cc.tags_text = value
                    self:refresh_title()
                end
                reopen()
            end)
        elseif field.key == "coauthors_wanted" then
            self.cc.coauthors_wanted = self.cc.coauthors_wanted ~= true
            self:refresh_title()
            log.info("Allow contributors: " .. (self.cc.coauthors_wanted and "yes" or "no"))
            reopen()
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
                reopen()
            end)
        end
    end)
end

--- Jump to an already-open workspace for this kata, if any.
---@param id string
---@return boolean jumped
local function focus_existing(id)
    return ui_utils.focus_existing_tab(_Cw_state.kata_editors, function(ws)
        return ws.model.id == id
    end)
end

--- Filetype for a pane: the solution panes use the kata's language, the
--- fixture panes the language its tests are written in (they differ for
--- SQL/Solidity/BF), and the description is markdown.
---@param kind string
---@return string
function KataEditor:pane_filetype(kind)
    local filetypes = require("codewars.languages.filetypes")
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
                self:refresh_title_soon()
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

    -- Stop any in-flight publish poll from outliving this workspace.
    if self._publish_token then
        self._publish_token.live = false
    end

    local rescued = false

    -- Neovim only guards the DISPLAYED buffer on close, so a dirty HIDDEN
    -- pane could be destroyed with no prompt at all. Stash the whole model
    -- (every language, every pane, plus the metadata) before the buffers go.
    if self:is_dirty() then
        -- build_model() carries the LIVE description (it lives in a pane, not
        -- in self.cc), so stash from it rather than from cc.
        local model = self:build_model()
        local path = require("codewars.cache.kata_stash").save({
            id = self.model.id,
            name = self.cc.name,
            language = self.lang,
            languages = model.languages,
            code_challenge = model.code_challenge,
        })
        if path then
            log.info(("Unsaved kata edits stashed to %s"):format(path))
        else
            -- Deleting the buffers now would destroy the only remaining copy.
            -- Keep them: listed, named, and out of this workspace's control,
            -- so the user can still yank the text out by hand.
            rescued = true
            log.error("COULD NOT STASH unsaved kata edits — the buffers have been "
                .. "KEPT OPEN so nothing is lost. Copy them out, then :bd! them.")
        end
    end

    vim.schedule(function()
        if self.console then
            self.console:unmount()
        end
        if self.description then
            self.description:unmount()
        end
        for key, bufnr in pairs(self.bufs or {}) do
            ui_utils.rescue_or_delete(bufnr, rescued
                and ("RESCUED kata %s %s"):format(self.model.id:sub(1, 6), key) or nil)
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
    obj.versions = {} -- lang -> runtime id, filled in as the user picks
    obj.saved = {}
    return obj
end

return KataEditor
