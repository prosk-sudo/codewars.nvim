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

local arguments = {
    list = {
        difficulty = { "8", "7", "6", "5", "4", "3", "2", "1" },
        order = { "popularity", "newest", "oldest", "hardest", "easiest", "positive" },
    },
}

---@class cw.Commands
local cmd = {}

function cmd.help()
    local NuiPopup = require("nui.popup")
    local ui_utils = require("codewars-ui.utils")

    local help = {
        { "TRAINING",       "" },
        { "train <slug> [lang]", "Open a kata by slug or URL" },
        { "random [lang]",  "Open a random kata" },
        { "focus [lang] [category]", "Choose Today's Focus (re-run for the next kata)" },
        { "test",           "Quick test with example fixtures" },
        { "attempt",        "Full attempt with all tests" },
        { "submit",         "Finalize solution (after passing attempt)" },
        { "reset",          "Reset code to template" },
        { "",               "" },
        { "BROWSING",       "" },
        { "list",           "Browse all kata (with filters)" },
        { "completed",      "Browse completed kata" },
        { "solutions",      "View community solutions" },
        { "leaderboard",    "Top 500 leaderboard (4 categories)" },
        { "kumite",         "Browse Freestyle Sparring (kumite)" },
        { "kumite open <id|url>", "Open a kumite by id or link" },
        { "kumite fork",    "Fork the current kumite to edit it" },
        { "open",           "Open kata in browser" },
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

    if ok then
        api.nvim_set_current_tabpage(tabp)
        ui.win_set_buf(winid, bufnr)
    else
        _Cw_state.menu:remount()
    end
end

function cmd.train(options)
    local slug = options._positional and options._positional[1]
    if not slug then
        return log.error("Usage: :CW train <slug> [language]")
    end

    local utils = require("codewars.utils")
    slug = utils.parse_slug(slug)

    local lang = config.lang
    local lang_explicit = false
    if options._positional and options._positional[2] then
        lang = options._positional[2]
        lang_explicit = true
    end

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

    local solutions_api = require("codewars.api.solutions")
    log.info("Fetching solutions...")
    solutions_api.fetch(k.kata_id, k.lang, function(sols, err)
        if err then
            return log.error("Failed to fetch solutions: " .. err.msg)
        end
        if not sols or #sols == 0 then
            -- solutions.fetch already logged the accurate empty-case message
            -- (beta pending approval / none yet / parse drift)
            return
        end
        local Solutions = require("codewars-ui.popup.solutions")
        Solutions:new(sols, k.lang):show()
    end, { unranked = require("codewars.theme").is_unranked(k.rank) })
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
local function open_random_kata(lang)
    local item, err = require("codewars.cache.problemlist_utils").random_for_lang(lang)
    if err then return log.warn(err) end
    require("codewars-ui.kata"):new(item.slug or item.id, lang):mount()
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

--- Resolve and open a kata for a focus category + language.
--- Random resolves client-side; the other categories hit the trainer
--- endpoint. Every invocation fetches a fresh kata — same behavior as
--- clicking a focus on codewars.com repeatedly.
---@param lang string
---@param category string
local function focus_run(lang, category)
    if category == "random" then
        return open_random_kata(lang)
    end

    log.info(("Fetching next '%s' kata for %s..."):format(category, lang))
    require("codewars.api.trainer").next_kata(category, lang, function(kata, err)
        if err then return log.err(err) end
        require("codewars-ui.kata"):new(kata.slug, lang):mount()
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
    if cat_arg ~= "random" and not trainer.STRATEGIES[cat_arg] then
        log.error(("Unknown focus category: %s (fundamentals|rank_up|practice_and_repeat|beta|random)"):format(cat_arg))
        return nil, nil
    end

    return lang_arg, cat_arg
end

--- :CW focus [lang] [category] — Choose Today's Focus.
--- Re-running the same focus serves the next kata, like the website.
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

function cmd.cache_update()
    local utils = require("codewars.utils")
    utils.auth_guard()
    local problemlist = require("codewars.cache.problemlist")
    problemlist.update({}, function(items)
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
        opts.rank = vim.tbl_map(function(d)
            return -tonumber(d)
        end, options.difficulty)
    end

    -- Parse order: order=popularity (default), newest, hardest
    if options.order then
        local order_map = {
            popularity = "popularity+desc",
            newest = "sort_date+desc",
            oldest = "sort_date+asc",
            hardest = "rank_id+desc",
            easiest = "rank_id+asc",
            positive = "satisfaction_percent+desc,total_completed+desc",
        }
        opts.order = order_map[options.order[1]] or "popularity+desc"
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
    local parts = vim.split(vim.trim(args), "%s+")
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
            return vim.tbl_filter(function(key)
                return not vim.tbl_contains(vals, key) and key:find(vals[#vals], 1, true) == 1
            end, cmds._args[s[1]])
        end
    end

    return vim.tbl_filter(function(key)
        return not vim.tbl_contains(args, key) and key:find(txt, 1, true) == 1
    end, keys)
end

function cmd.exec(args)
    local cmds = cmd.commands
    local options = vim.empty_dict()
    local positional = {}

    local parts = vim.split(vim.trim(args.args), "%s+", { trimempty = true })

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
    api.nvim_create_user_command("CW", cmd.exec, {
        bar = true,
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
