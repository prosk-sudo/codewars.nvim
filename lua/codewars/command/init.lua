local log = require("codewars.logger")
local config = require("codewars.config")
local api = vim.api

local lang_slugs = vim.tbl_map(function(l) return l.slug end, require("codewars.config.langs"))

-- Keep in sync with picker.focus_categories keys and trainer.STRATEGIES.
-- Deliberately a literal: deriving from the picker would eager-load the
-- telescope chain, deriving from trainer would eager-load plenary.curl,
-- and vim.tbl_keys would lose this stable display order.
local focus_category_keys = { "fundamentals", "rank_up", "practice_and_repeat", "beta", "random" }

-- Keep in sync with api/leaderboard.CATEGORIES (literal for the same
-- lazy-loading reasons as focus_category_keys above).
local leaderboard_category_keys = { "overall", "kata", "authored", "ranks" }

-- Keep in sync with codewars-ui/kata_editor.PANES (literal so completion does
-- not eager-load the UI chain, same reasoning as the two lists above).
local kata_pane_keys = { "answer", "setup", "fixture", "example", "description" }

local arguments = {
    list = {
        difficulty = { "8", "7", "6", "5", "4", "3", "2", "1" },
        -- Keep in sync with picker.sort_modes keys (literal so completion does
        -- not eager-load telescope, same reasoning as the lists below).
        order = { "popularity", "name", "satisfaction", "hardest", "easiest", "shuffle" },
    },
}

---@class cw.Commands
local cmd = {}

function cmd.help()
    local NuiPopup = require("nui.popup")
    local ui_utils = require("codewars-ui.utils")

    local help = {
        { "TRAINING",       "" },
        { "train <slug> [lang]", "Open a kata by title, slug or URL" },
        { "random [lang]",  "Open a random kata" },
        { "focus [lang] [category]", "Choose Today's Focus (re-run returns the same kata)" },
        { "focus skip", "Skip the current focus kata and open the next" },
        { "test",           "Quick test with example fixtures" },
        { "attempt",        "Full attempt with all tests" },
        { "submit",         "Finalize solution (after passing attempt)" },
        { "reset",          "Reset code to template" },
        { "template on|off", "Apply or remove your solution template" },
        { "",               "" },
        { "BROWSING",       "" },
        { "list",           "Browse all kata (with filters)" },
        { "completed",      "Browse completed kata" },
        { "solutions",      "View community solutions" },
        { "leaderboard",    "Top 500 leaderboard (4 categories)" },
        { "kumite",         "Browse Freestyle Sparring (kumite)" },
        { "kumite open <id|url>", "Open a kumite by id or link" },
        { "kumite fork",    "Fork the current kumite to edit it" },
        { "kumite new [lang]", "Start a fresh kumite from scratch" },
        { "kumite save",    "Save the kumite as a draft on codewars.com" },
        { "kumite publish", "Publish the saved kumite publicly" },
        { "kumite unpublish", "Hide a published kumite again (reversible)" },
        { "kumite convert", "Convert the kumite into a new kata" },
        { "open",           "Open kata in browser" },
        { "",               "" },
        { "AUTHORING A KATA", "" },
        { "kata open <id|url> [lang]", "Open a kata you author in the editor" },
        { "kata pane [name]", "Show a field (answer|setup|fixture|example|description)" },
        { "kata meta",      "Edit name, discipline, rank, tags, contributors" },
        { "kata lang",      "Switch the language being edited, or add one" },
        { "kata version",   "Pick the runtime version for the current language" },
        { "kata validate",  "Run your solution against the test cases" },
        { "kata save",      "Save the kata draft on codewars.com" },
        { "kata publish",   "Publish the kata publicly (confirms first)" },
        { "kata unpublish", "Take a published kata back to a draft" },
        { "kata delete",    "Delete the kata for good (confirms first)" },
        { "g1 … g5",        "Switch panes inside the kata editor" },
        { "",               "" },
        { "UI TOGGLES",     "" },
        { "desc",           "Toggle description split" },
        { "console",        "Toggle test console" },
        { "testcases",      "Toggle test cases split" },
        { "info",           "Show kata info" },
        { "",               "" },
        { "SETTINGS",       "" },
        { "lang",           "Change language for current kata" },
        { "lang default [lang]", "Set/show default language (persisted)" },
        { "cookie",         "Set browser cookies" },
        { "cookie delete",  "Sign out" },
        { "",               "" },
        { "CACHE",          "" },
        { "cache update",   "Refresh problem list (all languages)" },
        { "cache clear",    "Clear all session caches" },
        { "",               "" },
        { "OTHER",          "" },
        { "stats [user]",   "Show user stats" },
        { "doctor",         "Health check (deps, auth, cache)" },
        { "menu",           "Open dashboard menu" },
        { "exit",           "Close codewars.nvim" },
        { "",               "" },
        { "KATA LIST KEYS", "" },
        { "Ctrl-s",         "Sort (shuffle, name, satisfaction)" },
        { "Ctrl-l",         "Filter by language" },
        { "Ctrl-d",         "Filter by difficulty" },
        { "Ctrl-r",         "Reset all filters" },
    }

    local lines = {}
    local highlights = {}

    table.insert(lines, "")
    for _, entry in ipairs(help) do
        local cmd_name, desc = entry[1], entry[2]
        if desc == "" and cmd_name ~= "" then
            table.insert(lines, "  " .. cmd_name)
            table.insert(highlights, { #lines - 1, 0, -1, "Title" })
        elseif cmd_name == "" then
            table.insert(lines, "")
        else
            local padding = string.rep(" ", math.max(1, 24 - #cmd_name))
            local line = "    :CW " .. cmd_name .. padding .. desc
            if cmd_name:match("^Ctrl") then
                line = "    " .. cmd_name .. padding .. desc
            end
            table.insert(lines, line)
            table.insert(highlights, { #lines - 1, 4, 4 + #cmd_name + 4, "codewars_shortcut" })
        end
    end
    table.insert(lines, "")

    local popup = NuiPopup({
        enter = true,
        focusable = true,
        relative = "editor",
        position = "50%",
        size = { width = 75, height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8)) },
        border = {
            style = "rounded",
            text = { top = " Help ", top_align = "center" },
        },
        buf_options = { modifiable = true, readonly = false },
        win_options = { winhighlight = "FloatBorder:codewars_header" },
    })

    popup:mount()
    ui_utils.buf_set_lines(popup.bufnr, lines)

    local ns = vim.api.nvim_create_namespace("codewars_help")
    for _, hl in ipairs(highlights) do
        pcall(vim.api.nvim_buf_add_highlight, popup.bufnr, ns, hl[4], hl[1], hl[2], hl[3])
    end

    popup:map("n", "q", function() popup:unmount() end)
    popup:map("n", "<Esc>", function() popup:unmount() end)
    popup:on("BufLeave", function() popup:unmount() end)
end

function cmd.menu()
    if not _Cw_state.menu then
        return
    end

    local winid, bufnr = _Cw_state.menu.winid, _Cw_state.menu.bufnr
    local ok, tabp = pcall(api.nvim_win_get_tabpage, winid)
    local ui = require("codewars-ui.utils")

    if ok and bufnr and api.nvim_buf_is_valid(bufnr) then
        api.nvim_set_current_tabpage(tabp)
        ui.win_set_buf(winid, bufnr)
    else
        -- Window gone, or the buffer was wiped from under it: rebuild
        -- rather than silently showing nothing.
        _Cw_state.menu:remount()
    end
end

function cmd.train(options)
    local pos = vim.list_slice(options._positional or {})
    if #pos == 0 then
        return log.error("Usage: :CW train <title|slug|url> [language]")
    end

    local utils = require("codewars.utils")
    local lang = config.lang
    local lang_explicit = false
    -- A title is typed as bare words (:CW train Unique In Order python), so
    -- the language is whichever trailing word names one. With exactly two
    -- words the second is taken as a language and an unknown one is
    -- rejected here (with the quoting hint) instead of being folded into the
    -- slug or reaching Kata:path's assert; a two-word title is quoted.
    if #pos >= 2 then
        local last = pos[#pos]
        if utils.get_lang(last) then
            lang = last
            lang_explicit = true
            pos[#pos] = nil
        elseif #pos == 2 then
            utils.resolve_lang_arg(last)
            return log.info(('If "%s %s" is a kata title, quote it: :CW train "%s %s"'):format(pos[1], last, pos[1], last))
        end
    end
    local slug = utils.parse_slug(table.concat(pos, " "))

    utils.auth_guard()

    local Kata = require("codewars-ui.kata")
    local k = Kata:new(slug, lang)
    k._lang_explicit = lang_explicit
    k:mount()
end

--- Run `action` now if signed in, otherwise prompt for a cookie and resume
--- it on success (design §3.6 auth-resume; T12 — a closure through the
--- existing cookie_prompt, no pending-action store). Cancel drops it.
---@param action fun()
function cmd.with_auth(action)
    if require("codewars.cache.cookie").get() then
        return action()
    end
    log.info("Sign in to continue…")
    cmd.cookie_prompt(function(ok)
        if ok then action() end
    end)
end

function cmd.test()
    local utils = require("codewars.utils")

    -- A kumite workspace in this tab takes priority; its runner needs auth
    -- but no kata session, and resumes after sign-in.
    local kw = utils.curr_kumite()
    if kw then
        return cmd.with_auth(function()
            kw.console:run("test")
        end)
    end

    utils.auth_guard()
    local k = utils.curr_kata()
    if k then
        k.console:run("test")
    end
end

function cmd.attempt()
    local utils = require("codewars.utils")
    utils.auth_guard()
    local k = utils.curr_kata()
    if k then
        k.console:run("attempt")
    end
end

function cmd.submit()
    local utils = require("codewars.utils")
    utils.auth_guard()
    local k = utils.curr_kata()
    if k then
        k.console:run("submit")
    end
end

function cmd.solutions()
    local utils = require("codewars.utils")
    utils.auth_guard()
    local k = utils.curr_kata()
    if not k then return end

    require("codewars-ui.popup.solutions").fetch_and_show(k)
end

--- Fetch and show one leaderboard category.
---@param category_key string
local function leaderboard_show(category_key)
    log.info("Fetching leaderboard...")
    require("codewars.api.leaderboard").fetch(category_key, function(entries, err)
        if err then
            return log.err(err)
        end
        local Leaderboard = require("codewars-ui.popup.leaderboard")
        Leaderboard:new(entries, category_key):show()
    end)
end

--- :CW leaderboard [category] — top-500 leaderboard.
--- No args opens the category picker. Public page: no auth required.
function cmd.leaderboard(options)
    local key = options._positional and options._positional[1]
    if key then
        if not vim.tbl_contains(leaderboard_category_keys, key) then
            return log.error(("Unknown leaderboard category: %s (overall|kata|authored|ranks)"):format(key))
        end
        return leaderboard_show(key)
    end

    require("codewars.picker").leaderboard_category(leaderboard_show)
end

--- :CW kumite — browse Freestyle Sparring (public; works signed out).
function cmd.kumite()
    require("codewars.picker").kumite_browse()
end

--- :CW kumite open <id|url> — open a kumite directly (design §3.2).
function cmd.kumite_open(options)
    local ref = options._positional and options._positional[1]
    local id = require("codewars.api.kumite").parse_ref(ref)
    if not id then
        return log.error("Usage: :CW kumite open <id|url> — paste a /kumite/… link or a 24-hex id")
    end

    log.info("Loading kumite…")
    require("codewars.api.kumite").fetch_snippet(id, function(snippet, err)
        if err then
            return log.err(err)
        end
        vim.schedule(function()
            require("codewars-ui.kumite"):new(snippet):mount()
        end)
    end)
end

--- :CW kumite fork — turn the current kumite into an editable local copy.
--- Local transition, no auth (running the fork later prompts for it).
function cmd.kumite_fork()
    local kw = require("codewars.utils").curr_kumite()
    if not kw then
        return log.error("No kumite here. Open one with :CW kumite, then fork.")
    end
    kw:fork()
end

--- :CW kumite save — save the current kumite as a draft on codewars.com.
--- Needs auth (a real POST/PUT); signed out, prompts to sign in then resumes.
function cmd.kumite_save()
    local kw = require("codewars.utils").curr_kumite()
    if not kw then
        return log.error("No kumite here. Open or start one first, then save.")
    end
    cmd.with_auth(function()
        kw:save()
    end)
end

--- :CW kumite publish — publish the current kumite publicly on codewars.com.
--- Needs auth; the workspace confirms and requires a saved, passing draft.
function cmd.kumite_publish()
    local kw = require("codewars.utils").curr_kumite()
    if not kw then
        return log.error("No kumite here. Open or start one first, then publish.")
    end
    cmd.with_auth(function()
        kw:publish()
    end)
end

--- :CW kumite unpublish — hide a published kumite (reversible). Needs auth.
function cmd.kumite_unpublish()
    local kw = require("codewars.utils").curr_kumite()
    if not kw then
        return log.error("No kumite here. Open one first, then unpublish.")
    end
    cmd.with_auth(function()
        kw:unpublish()
    end)
end

--- :CW kumite convert — convert the current kumite into a new kata (creates a
--- kata, hides the kumite). Needs auth; the workspace confirms first.
function cmd.kumite_convert()
    local kw = require("codewars.utils").curr_kumite()
    if not kw then
        return log.error("No kumite here. Open or save one first, then convert.")
    end
    cmd.with_auth(function()
        kw:convert()
    end)
end

--- :CW kumite new [language] — start a fresh kumite from scratch. Opens a
--- blank editable workspace you can write and run locally, then persist with
--- `:CW kumite save` / `publish`. No auth needed to start (running and saving
--- prompt for sign-in).
function cmd.kumite_new(options)
    local kumite_api = require("codewars.api.kumite")

    local function start(lang)
        vim.ui.input({ prompt = "Kumite title: ", default = "Untitled kumite" }, function(title)
            if not title then return end -- cancelled
            local snippet = {
                id = "local-" .. tostring(vim.loop.now()),
                title = title ~= "" and title or "Untitled kumite",
                description = "",
                language = lang,
                code = require("codewars.templates").render(lang, {
                    lang = lang,
                    starter = "",
                }),
                fixture = require("codewars.languages.fixtures").get(lang),
                ["package"] = "",
                test_framework = kumite_api.default_framework(lang),
                language_version = kumite_api.default_version(lang),
                state = "draft",
                author = config.user.username ~= "" and config.user.username or nil,
            }
            require("codewars-ui.kumite"):new(snippet, { state = "local_new" }):mount()
            log.info("New kumite — write your code and a fixture, then :CW test to run it.")
        end)
    end

    local lang_arg = options._positional and options._positional[1]
    if lang_arg then
        local utils = require("codewars.utils")
        if not utils.resolve_lang_arg(lang_arg) then
            return
        end
        return start(lang_arg)
    end
    require("codewars.picker").pick_language(start)
end

--- The kata authoring workspace in this tab, or nil after reporting why.
---@param verb string what the caller wanted to do, for the message
---@return cw.ui.KataEditor?
local function curr_kata_editor(verb)
    local ws = require("codewars.utils").curr_kata_editor()
    if not ws then
        log.error(("No kata editor here. Open one with :CW kata open <id|url>, then %s."):format(verb))
        return nil
    end
    return ws
end

--- :CW kata open <id|url> [lang] — open a kata you author in the editor
--- (design KP1b/KP2). Needs auth: the edit page is yours, not public. With no
--- language, Codewars redirects to the kata's own default.
function cmd.kata_open(options)
    local positional = options._positional or {}
    local id = require("codewars.api.kata").parse_ref(positional[1])
    if not id then
        return log.error("Usage: :CW kata open <id|url> [lang] — paste a /kata/… link or a 24-hex id")
    end

    local lang = positional[2]
    if lang and not require("codewars.utils").resolve_lang_arg(lang) then
        return
    end

    cmd.with_auth(function()
        log.info("Loading the kata editor…")
        require("codewars.api.kata").load(id, lang, function(model, err)
            if err then
                return log.err(err)
            end
            vim.schedule(function()
                require("codewars-ui.kata_editor"):new(model):mount()
            end)
        end)
    end)
end

--- :CW kata pane <name> — show one of the editor's five fields. `g1`…`g5` do
--- the same from inside the workspace; with no name it cycles.
function cmd.kata_pane(options)
    local ws = curr_kata_editor("switch panes")
    if not ws then
        return
    end
    local key = options._positional and options._positional[1]
    if not key then
        return ws:cycle_pane(1)
    end
    ws:show_pane(key)
end

--- :CW kata meta — edit name / discipline / rank / tags / contributors.
function cmd.kata_meta()
    local ws = curr_kata_editor("edit its details")
    if ws then
        ws:edit_meta()
    end
end

--- :CW kata lang — switch the language being edited, or add one to the kata.
function cmd.kata_lang()
    local ws = curr_kata_editor("switch its language")
    if ws then
        ws:choose_language()
    end
end

--- :CW kata version — pick the runtime the current language runs on.
function cmd.kata_version()
    local ws = curr_kata_editor("change its runtime")
    if ws then
        ws:choose_version()
    end
end

--- :CW kata validate — run the solution against the kata's own test cases.
--- Needs auth (it is a real runner call).
function cmd.kata_validate()
    local ws = curr_kata_editor("validate it")
    if ws then
        cmd.with_auth(function()
            ws:validate()
        end)
    end
end

--- :CW kata save — save the kata draft on codewars.com.
function cmd.kata_save()
    local ws = curr_kata_editor("save it")
    if ws then
        cmd.with_auth(function()
            ws:save()
        end)
    end
end

--- :CW kata publish — publish the kata publicly. The workspace confirms first
--- and refuses while there are unsaved edits; Codewars re-runs the tests.
function cmd.kata_publish()
    local ws = curr_kata_editor("publish it")
    if ws then
        cmd.with_auth(function()
            ws:publish()
        end)
    end
end

--- :CW kata unpublish — take a published kata back to a draft (reversible).
function cmd.kata_unpublish()
    local ws = curr_kata_editor("unpublish it")
    if ws then
        cmd.with_auth(function()
            ws:unpublish()
        end)
    end
end

--- :CW kata delete — delete the kata for good. Confirms with its name first.
function cmd.kata_delete()
    local ws = curr_kata_editor("delete it")
    if ws then
        cmd.with_auth(function()
            ws:delete()
        end)
    end
end

function cmd.desc_toggle()
    local utils = require("codewars.utils")
    local k = utils.curr_kata()
    if k and k.description then
        k.description:toggle()
    end
end

function cmd.testcases()
    local utils = require("codewars.utils")
    local k = utils.curr_kata()
    if not k then return end
    if k.testcase_split then
        k.testcase_split:toggle()
    end
end

function cmd.console()
    local utils = require("codewars.utils")
    local k = utils.curr_kata()
    if k and k.console then
        k.console:toggle()
    end
end

function cmd.info()
    local utils = require("codewars.utils")
    local k = utils.curr_kata()
    if not k then
        return
    end

    local lines = {
        ("Name: %s"):format(k.name or k.slug),
        ("Language: %s"):format(k.lang),
    }
    if k.rank then
        local theme = require("codewars.theme")
        table.insert(lines, ("Rank: %s"):format(theme.rank_str(k.rank)))
    end
    if k.tags and #k.tags > 0 then
        table.insert(lines, ("Tags: %s"):format(table.concat(k.tags, ", ")))
    end

    log.info(table.concat(lines, "\n"))
end

function cmd.stats(options)
    local username = options._positional and options._positional[1] or config.user.username
    local Stats = require("codewars-ui.popup.stats")
    Stats:new():show(username)
end

function cmd.completed()
    local picker = require("codewars.picker")
    picker.completed()
end

--- Open a random kata from the cached problem list (client-side).
---@param lang string
---@param on_mounted? fun() runs once the kata is actually on screen
---@return table? kata the mounted cw.ui.Kata instance (nil when the list is empty)
local function open_random_kata(lang, on_mounted)
    local item, err = require("codewars.cache.problemlist_utils").random_for_lang(lang)
    if err then return log.warn(err) end
    local kata = require("codewars-ui.kata"):new(item.slug or item.id, lang)
    kata._on_mounted = on_mounted
    kata:mount()
    return kata
end

function cmd.random(options)
    local utils = require("codewars.utils")
    utils.auth_guard()

    local lang = config.lang
    local lang_arg = options._positional and options._positional[1]
    if lang_arg then
        if not utils.resolve_lang_arg(lang_arg) then
            return
        end
        lang = lang_arg
    end

    open_random_kata(lang)
end

-- Last focus target, so `:CW focus skip` knows which queue to advance and
-- which mounted kata the skip replaces. In-memory only: the server owns the
-- focus pointer itself.
local _last_focus = nil ---@type { lang: string, category: string, slug: string?, kata: table? }?

--- Forget the remembered focus kata. Called on an identity change: the
--- queue it came from belongs to the previous account, so a `:CW focus
--- skip` after signing in as someone else must not act on it.
function cmd.forget_focus()
    _last_focus = nil
end

--- The remembered focus kata, read-only (slug/lang/category), or nil.
---@return { lang: string, category: string, slug: string? }?
function cmd.current_focus()
    if not _last_focus then return nil end
    return { lang = _last_focus.lang, category = _last_focus.category, slug = _last_focus.slug }
end

-- One focus fetch at a time, enforced HERE and not just in the api layer.
-- The api mutex rejects the second request, but by then the old code had
-- already overwritten _last_focus — so a later `:CW focus skip` would
-- advance the queue of a focus that never actually loaded, and a dequeue
-- cannot be undone. Serializing at the command layer means _last_focus is
-- only ever written for a fetch that succeeded.
local _focus_inflight = false

-- Categories resolved entirely client-side, with no server queue behind
-- them. One source of truth for every place that has to treat them
-- differently: resolving, skipping, validating, and advancing on complete.
local LOCAL_CATEGORIES = { random = true }

--- Close the kata window a skip abandons.
---
--- IDENTITY ONLY, deliberately. Matching by slug would also match a window
--- the user opened themselves (`:CW train <same-slug>`), and Kata:unmount
--- force-closes the window, which force-deletes the buffer and discards
--- unsaved solution code with no prompt. When that exact instance has no
--- live window — Kata:mount early-returned to a duplicate tab, or the
--- mount is still in flight — nothing is closed. A lingering tab is the
--- safe failure; eating someone's unsaved solution is not.
---@param prev { kata: table? }?
local function close_skipped_kata(prev)
    if not prev or not prev.kata then return end
    -- kata_tabp is the winid-validity primitive underneath curr_kata and
    -- detect_duplicate_kata (they reach it through kata_tabs, which filters
    -- to registered instances first). Here the instance is already known, so
    -- the liveness check alone is what matters.
    if not require("codewars.utils").kata_tabp(prev.kata) then return end
    pcall(prev.kata.unmount, prev.kata)
end

--- Mount the kata a focus served and record it on the given focus record.
--- Callers pass the record rather than assigning `_last_focus` here: a
--- focus_run callback must only update its OWN record, so a newer focus
--- issued while it was in flight is not clobbered.
---@param target table the focus record to fill in
---@param lang string
---@param kata { slug: string }
---@param on_mounted? fun()
local function mount_focus_kata(target, lang, kata, on_mounted)
    local ui = require("codewars-ui.kata"):new(kata.slug, lang)
    target.slug = kata.slug
    target.kata = ui
    ui._on_mounted = on_mounted
    ui:mount()
end

--- Resolve and open the current kata for a focus category + language.
--- Random resolves client-side; the other categories peek the server-side
--- trainer queue (idempotent — re-running returns the same kata until it is
--- solved or skipped via :CW focus skip).
---@param lang string
---@param category string
---@param on_mounted? fun() runs once the served kata is actually on screen
local function focus_run(lang, category, on_mounted)
    if LOCAL_CATEGORIES[category] then
        -- No server queue behind this one, so a stale record here can never
        -- cause a dequeue; resolve it directly.
        local kata = open_random_kata(lang, on_mounted)
        if kata then
            _last_focus = { lang = lang, category = category, slug = kata.slug, kata = kata }
        end
        return
    end

    if _focus_inflight then
        return log.warn("Already fetching a focus kata — try again in a moment.")
    end
    _focus_inflight = true

    log.info(("Fetching the current '%s' kata for %s..."):format(category, lang))
    require("codewars.api.trainer").next_kata(category, lang, function(kata, err)
        _focus_inflight = false
        if err then return log.err(err) end
        -- Only now is this the current focus. Recording it earlier is what
        -- let a rejected second request point a later skip at the wrong queue.
        local lf = { lang = lang, category = category }
        _last_focus = lf
        mount_focus_kata(lf, lang, kata, on_mounted)
    end)
end

--- Validate positional args for :CW focus.
---@return string? lang, string? category (nil, nil) when args are absent/invalid
local function focus_args(options)
    local pos = options._positional or {}
    local lang_arg, cat_arg = pos[1], pos[2]
    if not (lang_arg and cat_arg) then
        log.error("Usage: :CW focus [language] [category] — both are required (no args opens the pickers)")
        return nil, nil
    end

    local utils = require("codewars.utils")
    if not utils.resolve_lang_arg(lang_arg) then
        return nil, nil
    end

    local trainer = require("codewars.api.trainer")
    if not LOCAL_CATEGORIES[cat_arg] and not trainer.STRATEGIES[cat_arg] then
        log.error(("Unknown focus category: %s (fundamentals|rank_up|practice_and_repeat|beta|random)"):format(cat_arg))
        return nil, nil
    end

    return lang_arg, cat_arg
end

--- :CW focus [lang] [category] — Choose Today's Focus.
--- Re-running the same focus returns the same kata (server-side pointer);
--- `:CW focus skip` advances to the next one.
function cmd.focus(options)
    local utils = require("codewars.utils")
    utils.auth_guard()

    local pos = options._positional or {}
    if #pos > 0 then
        local lang, category = focus_args(options)
        if lang and category then
            focus_run(lang, category)
        end
        return -- invalid args already reported by focus_args
    end

    local picker = require("codewars.picker")
    picker.pick_language(function(picked_lang)
        picker.focus_category(function(picked_cat)
            focus_run(picked_lang, picked_cat)
        end)
    end)
end

--- :CW focus skip — pop the current focus kata, open the next one, and close
--- the one it replaces.
---
--- The old kata closes only once the replacement is ON SCREEN, not merely
--- once the trainer fetch returned: Kata:mount is itself async and can fail
--- (404 on a stale id, expired cookie), and closing on fetch-success alone
--- would leave the user with nothing open.
function cmd.focus_skip()
    local utils = require("codewars.utils")
    utils.auth_guard()

    if not _last_focus then
        return log.error("No focus to skip — run :CW focus first.")
    end
    local prev = _last_focus
    local lang, category = prev.lang, prev.category
    local function close_prev() close_skipped_kata(prev) end

    if LOCAL_CATEGORIES[category] then
        -- Client-side random has no server queue; a skip is just a re-roll.
        -- If the re-roll lands on the same kata, mount jumps to the open tab
        -- and never fires on_mounted, so nothing is closed. Correct.
        return focus_run(lang, category, close_prev)
    end

    if _focus_inflight then
        return log.warn("Already fetching a focus kata — try again in a moment.")
    end
    _focus_inflight = true

    log.info(("Skipping the current '%s' kata for %s..."):format(category, lang))
    require("codewars.api.trainer").skip(category, lang, function(kata, err)
        _focus_inflight = false
        if err then return log.err(err) end
        local lf = { lang = lang, category = category }
        _last_focus = lf
        mount_focus_kata(lf, lang, kata, close_prev)
    end)
end

--- Called by the runner after a kata is finalized. The trainer queue only
--- moves on a dequeue, so completing a focus kata leaves it at the head and
--- the next :CW focus would re-serve it. Pop the queue when the finalized
--- kata is the one this focus served.
---@param kata table the finalized cw.ui.Kata
function cmd.focus_kata_completed(kata)
    local lf = _last_focus
    if not lf or not kata or LOCAL_CATEGORIES[lf.category] then return end
    if lf.lang ~= kata.lang then return end

    local matches = (lf.kata ~= nil and lf.kata == kata)
        or (lf.slug ~= nil and (lf.slug == kata.slug or lf.slug == kata.kata_id))
    if not matches then return end

    -- Pass what we believe the head is: advance re-checks before popping, so
    -- a queue that moved while this kata was open is left alone.
    local expected = { slug = lf.slug, id = kata.kata_id }
    require("codewars.api.trainer").advance(lf.category, lf.lang, expected, function(err)
        if err then
            -- Best effort: the completed self-heal in trainer.next_kata
            -- catches this kata on the next focus anyway.
            return log.debug(("focus: could not advance the %s queue: %s"):format(
                lf.category, tostring(err.msg)))
        end
        -- Head consumed; nothing left for a later skip to close.
        lf.slug, lf.kata = nil, nil
    end)
end

function cmd.cache_update()
    local utils = require("codewars.utils")
    utils.auth_guard()
    local problemlist = require("codewars.cache.problemlist")
    problemlist.update({}, function(items, partial)
        -- An aborted run already surfaced its own error; claiming the list
        -- was updated right underneath that is just contradictory.
        if partial then return end
        log.info(("Problem list updated: %d kata"):format(#items))
    end)
end

function cmd.cache_clear()
    local session = require("codewars.cache.session")
    local count = session.clear_all()
    log.info(("Session cache cleared (%d files removed)"):format(count))
end

function cmd.list(options)
    local utils = require("codewars.utils")
    utils.auth_guard()
    local picker = require("codewars.picker")
    local opts = {}

    -- Parse difficulty filter: difficulty=8,7 -> rank={-8,-7}
    if options.difficulty then
        opts.rank = {}
        for _, d in ipairs(options.difficulty) do
            local n = tonumber(d)
            if not n or n < 1 or n > 8 or n % 1 ~= 0 then
                return log.error(("Invalid difficulty: %s (expected a kyu from 1 to 8)"):format(d))
            end
            opts.rank[#opts.rank + 1] = -n
        end
    end

    -- order= selects the picker's sort mode. The list is the cached
    -- catalogue, which carries rank, name and satisfaction but no dates, so
    -- these are the orders that can be honoured (the old newest/oldest were
    -- accepted and silently ignored).
    if options.order then
        local order = options.order[1]
        if not vim.tbl_contains(arguments.list.order, order) then
            return log.error(("Invalid order: %s (expected one of %s)"):format(
                tostring(order), table.concat(arguments.list.order, ", ")))
        end
        opts.sort_key = order
    end

    picker.problems(opts)
end

function cmd.change_lang()
    local utils = require("codewars.utils")
    local k = utils.curr_kata()
    if not k then
        return
    end

    local picker = require("codewars.picker")
    picker.language(k)
end

function cmd.set_default_lang(options)
    local lang_arg = options._positional and options._positional[1]
    if not lang_arg then
        log.info(("Current default language: %s"):format(config.lang))
        return
    end

    local utils = require("codewars.utils")
    local lang_info = utils.resolve_lang_arg(lang_arg)
    if not lang_info then
        return
    end

    config.save_lang(lang_arg)
    log.info(("Default language set to: %s (saved)"):format(lang_info.lang))
end

function cmd.reset()
    local utils = require("codewars.utils")
    local k = utils.curr_kata()
    if k then
        k:reset_code()
    end
end

--- Turn solution templates on or off, and bring the open kata along.
---
--- The switch is global and persisted; the buffer rewrite is a courtesy on top
--- of it, since flipping the switch and then staring at a buffer that still has
--- the old shape is the confusing half. It refuses rather than guesses when the
--- buffer has drifted from the template, and says why.
---@param on boolean
local function set_templates(on)
    local templates = require("codewars.templates")
    local was = templates.is_enabled()
    templates.set_enabled(on)

    -- kata_in_tab, not curr_kata: this is a global setting, and running it from
    -- the dashboard is ordinary, not an error worth logging.
    local k = require("codewars.utils").kata_in_tab()
    local changed = k and k:retemplate(on and "wrap" or "strip")

    if was == on and not changed then
        return log.info(("Templates are already %s."):format(on and "on" or "off"))
    end
    log.info(("Templates %s%s."):format(on and "on" or "off", changed and " — this buffer updated" or ""))
end

function cmd.template_on()
    set_templates(true)
end

function cmd.template_off()
    set_templates(false)
end

function cmd.template_status()
    local templates = require("codewars.templates")
    local parts = { ("Templates are %s."):format(templates.is_enabled() and "on" or "off") }

    local k = require("codewars.utils").kata_in_tab()
    if k then
        parts[#parts + 1] = templates.is_configured(k.lang)
            and ("A %s template is configured."):format(k.lang)
            or ("No %s template is configured."):format(k.lang)
    end

    log.info(table.concat(parts, " "))
end

function cmd.open()
    local utils = require("codewars.utils")
    local k = utils.curr_kata()
    if not k then
        return
    end

    local url = "https://www.codewars.com/kata/" .. k.slug
    if vim.ui.open then
        vim.ui.open(url)
    else
        local os_name = vim.loop.os_uname().sysname
        local open_cmd
        if os_name == "Darwin" then
            open_cmd = ("open '%s'"):format(url)
        elseif os_name == "Linux" then
            open_cmd = ("xdg-open '%s'"):format(url)
        else
            open_cmd = ('start "" "%s"'):format(url)
        end
        vim.fn.jobstart(open_cmd, { detach = true })
    end
end

function cmd.cookie_prompt(cb)
    -- cb may be the options table when called from :CW cookie command
    if type(cb) ~= "function" then cb = nil end

    local NuiInput = require("nui.input")
    local event = require("nui.utils.autocmd").event

    local popup_options = {
        relative = "editor",
        position = {
            row = "50%",
            col = "50%",
        },
        size = 60,
        border = {
            style = "rounded",
            text = {
                top = " Enter cookie (CSRF-TOKEN=...; _session_id=...) ",
                top_align = "left",
            },
        },
        win_options = {
            winhighlight = "Normal:Normal",
        },
    }

    local input = NuiInput(popup_options, {
        prompt = " > ",
        on_submit = function(value)
            local cookie = require("codewars.cache.cookie")
            local err = cookie.set(value)

            if not err then
                log.info("Sign-in successful")
            else
                log.error("Sign-in failed: " .. err)
            end

            if cb then
                pcall(cb, not err)
            end
        end,
    })

    input:mount()

    local keys = config.user.keys
    input:map("n", keys.toggle, function()
        input:unmount()
    end)
    input:on(event.BufLeave, function()
        input:unmount()
    end)
end

function cmd.sign_out()
    local cookie = require("codewars.cache.cookie")
    cookie.delete()
    log.info("Signed out")
end

function cmd.exit()
    local codewars = require("codewars")
    codewars.stop()
end

function cmd.start_with_cmd()
    if _Cw_state.menu then
        cmd.menu()
    else
        local codewars = require("codewars")
        codewars.show_menu()
    end
end

--- The one definition of "what counts as a key=value option token":
--- word-shaped keys only (difficulty=8). URLs and other '='-bearing
--- positionals (/kumite/{id}?sel={id}) are never options. Shared by
--- exec and parse/complete so the rule can't fork.
---@param token string
---@return string? key, string? value
local function split_option(token)
    return token:match("^([%w_]+)=(.*)$")
end

---@param args string
---@return string[], string[]
function cmd.parse(args)
    -- Same tokenizer as exec, so completion sees a quoted title as one
    -- argument too and offers the language at the right position.
    local parts = cmd.tokenize(args)
    if #parts == 0 then
        parts = { "" }
    end
    if args:sub(-1) == " " then
        parts[#parts + 1] = ""
    end

    local options = {}
    for _, part in ipairs(parts) do
        local opt = split_option(part)
        if opt then
            table.insert(options, opt)
        end
    end

    return parts, options
end

---@param tbl table
local function cmds_keys(tbl)
    return vim.tbl_filter(function(key)
        if type(key) ~= "string" then
            return false
        end
        if key:sub(1, 1) == "_" then
            return false
        end
        return true
    end, vim.tbl_keys(tbl))
end

---@param _ string
---@param line string
---@return string[]
function cmd.complete(_, line)
    local args, options = cmd.parse(line:gsub("CW%s", ""))
    return cmd.rec_complete(args, options, cmd.commands)
end

---@param args string[]
---@param options string[]
---@param cmds table
---@return string[]
function cmd.rec_complete(args, options, cmds)
    if not cmds or vim.tbl_isempty(args) then
        return {}
    end

    if not cmds._args and cmds[args[1]] then
        return cmd.rec_complete(args, options, cmds[table.remove(args, 1)])
    end

    local txt, keys = args[#args], cmds_keys(cmds)

    -- Positional completion (e.g., language as 2nd arg for train)
    if cmds._positional_complete then
        local pos_idx = #args
        local candidates = cmds._positional_complete[pos_idx]
        if candidates then
            return vim.tbl_filter(function(key)
                return key:find(txt, 1, true) == 1
            end, candidates)
        end
    end

    if cmds._args then
        local option_keys = cmds_keys(cmds._args)
        option_keys = vim.tbl_filter(function(key)
            return not vim.tbl_contains(options, key)
        end, option_keys)
        option_keys = vim.tbl_map(function(key)
            return ("%s="):format(key)
        end, option_keys)
        keys = vim.tbl_extend("force", keys, option_keys)

        local s = vim.split(txt, "=")
        if s[2] and cmds._args[s[1]] then
            local vals = vim.split(s[2], ",")
            -- Neovim replaces the whole word being completed, so each
            -- candidate must carry the `key=` and any values already typed
            -- (difficulty=8, -> difficulty=8,7), or the prefix vanishes.
            local head = txt:sub(1, #txt - #vals[#vals])
            local matches = vim.tbl_filter(function(key)
                return not vim.tbl_contains(vals, key) and key:find(vals[#vals], 1, true) == 1
            end, cmds._args[s[1]])
            return vim.tbl_map(function(key)
                return head .. key
            end, matches)
        end
    end

    return vim.tbl_filter(function(key)
        return not vim.tbl_contains(args, key) and key:find(txt, 1, true) == 1
    end, keys)
end

--- Split the raw `:CW` argument string into tokens. Whitespace separates
--- tokens; a "..." or '...' segment is one token with the quotes removed, so
--- a multi-word kata title survives (:CW train "Unique In Order" python).
---@param s string
---@return string[]
function cmd.tokenize(s)
    local parts, buf, quote = {}, nil, nil
    for c in (s or ""):gmatch(".") do
        if quote then
            if c == quote then
                quote = nil
            else
                buf = buf .. c
            end
        elseif (c == '"' or c == "'") and buf == nil then
            -- A quote only opens a group at the start of a token, so an
            -- apostrophe inside a word (it's-a-title) is ordinary text.
            quote = c
            buf = ""
        elseif c:match("%s") then
            if buf then
                parts[#parts + 1] = buf
                buf = nil
            end
        else
            buf = (buf or "") .. c
        end
    end
    if quote then
        -- Never closed: the quote was ordinary text, so fall back to the
        -- plain whitespace split rather than swallowing the rest of the line.
        return vim.split(vim.trim(s), "%s+", { trimempty = true })
    end
    if buf then
        parts[#parts + 1] = buf
    end
    return parts
end

function cmd.exec(args)
    local cmds = cmd.commands
    local options = vim.empty_dict()
    local positional = {}

    local parts = cmd.tokenize(args.args)

    for _, s in ipairs(parts) do
        local key, value = split_option(s)

        if key then
            options[key] = vim.split(value, ",", { trimempty = true })
        elseif cmds and type(cmds) == "table" and cmds[s:lower()] then
            cmds = cmds[s:lower()]
        else
            table.insert(positional, s)
        end
    end

    options._positional = positional

    if cmds and type(cmds) == "table" and type(cmds[1]) == "function" then
        local ok, err = pcall(cmds[1], options)
        if not ok then
            log.error(tostring(err))
        end
    elseif type(cmds) == "table" and cmds[1] == nil and parts[1] == nil then
        cmd.start_with_cmd()
    else
        log.error(("Invalid command: `%s %s`"):format(args.name, args.args))
    end
end

function cmd.setup()
    -- No `bar`: with -bar a double quote starts an Ex comment, so
    -- `:CW train "Unique In Order"` reached exec as just `train`.
    api.nvim_create_user_command("CW", cmd.exec, {
        bang = true,
        nargs = "*",
        desc = "Codewars",
        complete = cmd.complete,
    })
end

cmd.commands = {
    menu = { cmd.menu },
    exit = { cmd.exit },
    train = {
        cmd.train,
        _positional_complete = { nil, lang_slugs },
    },
    random = {
        cmd.random,
        _positional_complete = { lang_slugs },
    },
    focus = {
        cmd.focus,
        skip = { cmd.focus_skip },
        _positional_complete = { lang_slugs, focus_category_keys },
    },
    test = { cmd.test },
    attempt = { cmd.attempt },
    submit = { cmd.submit },
    solutions = { cmd.solutions },
    leaderboard = {
        cmd.leaderboard,
        _positional_complete = { leaderboard_category_keys },
    },
    kumite = {
        cmd.kumite,
        open = { cmd.kumite_open },
        fork = { cmd.kumite_fork },
        save = { cmd.kumite_save },
        publish = { cmd.kumite_publish },
        unpublish = { cmd.kumite_unpublish },
        convert = { cmd.kumite_convert },
        new = {
            cmd.kumite_new,
            _positional_complete = { lang_slugs },
        },
    },
    kata = {
        open = {
            cmd.kata_open,
            _positional_complete = { nil, lang_slugs },
        },
        pane = {
            cmd.kata_pane,
            _positional_complete = { kata_pane_keys },
        },
        meta = { cmd.kata_meta },
        lang = { cmd.kata_lang },
        version = { cmd.kata_version },
        validate = { cmd.kata_validate },
        save = { cmd.kata_save },
        publish = { cmd.kata_publish },
        unpublish = { cmd.kata_unpublish },
        delete = { cmd.kata_delete },
    },
    desc = {
        cmd.desc_toggle,
        toggle = { cmd.desc_toggle },
    },
    testcases = { cmd.testcases },
    console = { cmd.console },
    info = { cmd.info },
    stats = { cmd.stats },
    completed = { cmd.completed },
    list = {
        cmd.list,
        _args = arguments.list,
    },
    lang = {
        cmd.change_lang,
        default = {
            cmd.set_default_lang,
            _positional_complete = { lang_slugs },
        },
    },
    reset = { cmd.reset },
    template = {
        cmd.template_status,
        on = { cmd.template_on },
        off = { cmd.template_off },
    },
    open = { cmd.open },
    cookie = {
        cmd.cookie_prompt,
        update = { cmd.cookie_prompt },
        delete = { cmd.sign_out },
    },
    cache = {
        update = { cmd.cache_update },
        clear = { cmd.cache_clear },
    },
    doctor = { function()
        vim.cmd("checkhealth codewars")
    end },
    help = { cmd.help },
}

return cmd
