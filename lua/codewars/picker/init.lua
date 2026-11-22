local config = require("codewars.config")
local slice = require("codewars.picker.select")
local log = require("codewars.logger")
local theme = require("codewars.theme")

---@class cw.Picker
local picker = {}

-- Cached completed set (rebuilt per picker session)
local _completed_set = nil

function picker.invalidate_completed_cache()
    _completed_set = nil
end

local function build_completed_set(items)
    local set = {}
    for _, item in ipairs(items) do
        if item.slug then set[item.slug] = true end
        if item.id then set[item.id] = true end
    end
    return set
end

--- Run `cb` with the completed kata, fetched first if none, else cached while a stale list
--- refreshes. On `err`, `items` is only what is on disk. `opts.fetched_only` fetches unless a
--- full fetch ever completed, for callers that judge by the WHOLE list.
---@param cb fun(items: table[], err: table?)
---@param opts { fetched_only: boolean? }?
local function ensure_completed_items(cb, opts)
    local completed_cache = require("codewars.cache.completed")
    local items, is_stale, is_fetched = completed_cache.get()
    local signed_in = config.user.username ~= ""

    local needs_fetch = vim.tbl_isempty(items)
    if opts and opts.fetched_only then needs_fetch = not is_fetched end

    if needs_fetch and not signed_in and opts and opts.fetched_only then
        return cb(items, { msg = "no completed list has been fetched and you are not signed in" })
    end
    if needs_fetch and signed_in then
        log.info("Fetching completed kata...")
        return completed_cache.update(function(fetched_items, err)
            picker.invalidate_completed_cache()
            -- The fetched list, not the disk: a failed save may leave the old list
            -- or a damaged file there.
            vim.schedule(function() cb(fetched_items, err) end)
        end)
    end
    cb(items)
    if is_stale and signed_in then
        completed_cache.update(function()
            picker.invalidate_completed_cache()
        end)
    end
end

--- The same, as a set of completed slugs and ids.
---@param cb fun(set: table<string, boolean>)
local function ensure_completed_set(cb)
    ensure_completed_items(function(items)
        _completed_set = build_completed_set(items)
        cb(_completed_set)
    end)
end

local function rank_icon(rank_id)
    if not rank_id then return " " end
    local icons = require("codewars.icons").get()
    return icons.rank
end

local function rank_hl_from_id(rank_id)
    if not rank_id then return "codewars_normal" end
    return theme.rank_hl(rank_id)
end

local function rank_str(rank_name)
    if not rank_name then return "     " end
    return string.format("%-5s", rank_name)
end

local function status_icon(slug, completed_set)
    if completed_set[slug] then
        local icons = require("codewars.icons").get()
        return { icons.completed, "codewars_completed" }
    else
        return { " ", "codewars_normal" }
    end
end

local problemlist_utils = require("codewars.cache.problemlist_utils")
local dropdown = require("codewars.picker.dropdown")

-- The kata list's window. Shared so every list of kata opens the same way.
local LIST_LAYOUT = { width = 100, height = 0.8 }

-- Persistent filter state (remembered across picker reopens)
local _saved_sort_idx = 1
local _saved_lang_filter = config.lang
local _saved_rank_filter = nil

-- Sort modes
local sort_modes = {
    { key = "shuffle", label = "Shuffle" },
    { key = "name", label = "Name (A-Z)" },
    { key = "satisfaction", label = "Satisfaction (%)" },
    { key = "hardest", label = "Hardest first" },
    { key = "easiest", label = "Easiest first" },
    -- Needs a completion date, which only :CW completed's kata carry: the
    -- kata list does not offer it, and it is never remembered for the
    -- next list or :CW next.
    { key = "recent", label = "Recently completed", dated = true },
}

-- Exposed so `:CW list order=` completion/validation can be pinned to it.
picker.sort_modes = sort_modes

---@param key string
---@return integer? index into sort_modes
local function sort_index(key)
    for i, mode in ipairs(sort_modes) do
        if mode.key == key then return i end
    end
    return nil
end

-- Difficulty filter options
local difficulty_options = {
    { rank = nil, label = "All ranks" },
    { rank = -8, label = "8 kyu" },
    { rank = -7, label = "7 kyu" },
    { rank = -6, label = "6 kyu" },
    { rank = -5, label = "5 kyu" },
    { rank = -4, label = "4 kyu" },
    { rank = -3, label = "3 kyu" },
    { rank = -2, label = "2 kyu" },
    { rank = -1, label = "1 kyu" },
}

--- Test seam: the list sort, so its order is testable without a picker UI.
picker._sort_items = slice.sort_items

--- Show a telescope picker for a list of kata items.
---@param items table[]
---@param title string
---@param completed_set table<string, boolean>
---@param initial? { sort_key?: string, rank_filter?: integer|false } state the
--- caller asks for up front (`:CW list order=… difficulty=…`). It seeds THIS
--- picker's sort / rank filter in place of the remembered ones, so its menus
--- show what was asked for; the remembered state only changes when the user
--- touches a menu (save_state), never from a caller, so other list views are
--- not affected. rank_filter = false means "All ranks" explicitly.
function picker._show_kata_list(items, title, completed_set, initial)
    local use_select = dropdown.provider() == "select"
    -- Memoized telescope table lives in picker.dropdown; shared error path.
    local t
    if not use_select then
        t = dropdown.telescope()
        if not t then return end
    end
    initial = initial or {}

    local current_sort_idx = sort_index(initial.sort_key) or _saved_sort_idx
    local current_lang_filter = _saved_lang_filter
    local current_rank_filter = _saved_rank_filter
    if initial.rank_filter ~= nil then
        current_rank_filter = initial.rank_filter or nil
    end
    local reopen
    local cached_languages = problemlist_utils.collect_languages(items)
    -- Only kata you solved carry a completion date (:CW completed).
    local has_dates = false
    for _, item in ipairs(items) do
        if item.completedAt then has_dates = true break end
    end

    -- Remember only what the user just chose in a menu. Values seeded by a
    -- caller (`:CW list order=… difficulty=…`) are not persisted by touching
    -- an unrelated menu, so other list views never inherit them.
    ---@param field "sort"|"lang"|"rank"|nil nil = all three (the reset)
    local function save_state(field)
        if (field == "sort" or not field) and not sort_modes[current_sort_idx].dated then
            _saved_sort_idx = current_sort_idx
        end
        if field == "lang" or not field then _saved_lang_filter = current_lang_filter end
        if field == "rank" or not field then _saved_rank_filter = current_rank_filter end
    end

    local function reset_filters()
        current_sort_idx = 1
        current_lang_filter = nil
        current_rank_filter = nil
        save_state()
    end

    local function open_kata(item)
        local Kata = require("codewars-ui.kata")
        local slug = item.slug or item.id

        local lang = current_lang_filter
        if not lang then
            lang = config.lang
            if item.languages and #item.languages > 0 and not vim.tbl_contains(item.languages, lang) then
                lang = item.languages[1]
            end
        end

        Kata:new(slug, lang):mount()
    end

    --- Text columns of a kata row, shared by both backends.
    local function kata_columns(item)
        local rid = slice.rank_of(item)
        local rname = item.rank_name or (item.rank and item.rank.name) or ""
        local slug = item.slug or item.id

        -- Judged against the language you are filtering by, not the default:
        -- a kata valid for the selected filter is not "unavailable".
        local lang_available = true
        local judge_lang = current_lang_filter or config.lang
        if item.languages and #item.languages > 0 and judge_lang then
            lang_available = vim.tbl_contains(item.languages, judge_lang)
        end

        local display_name = item.name or slug
        if item.satisfaction then
            display_name = ("%s (%d%%)"):format(display_name, item.satisfaction)
        end

        return {
            rid = rid,
            rname = rname,
            hl = rank_hl_from_id(rid),
            slug = slug,
            warn_icon = lang_available and " " or "\u{f0205}",
            display_name = display_name,
        }
    end

    local function build_display_list()
        local filtered = problemlist_utils.filter_by_language(items, current_lang_filter)
        filtered = slice.filter_by_rank(filtered, current_rank_filter)
        local sorted = slice.sort_items(filtered, sort_modes[current_sort_idx].key)

        local lang_label = current_lang_filter or "All languages"
        local sort_label = sort_modes[current_sort_idx].label
        local rank_text = slice.rank_label(current_rank_filter)

        local controls = {
            { _control = "sort", label = ("  Sort: %s"):format(sort_label) },
            { _control = "lang", label = ("  Language: %s"):format(lang_label) },
            { _control = "rank", label = ("  Difficulty: %s (%d)"):format(rank_text, #filtered) },
            { _control = "separator" },
        }

        local display = {}
        vim.list_extend(display, controls)
        vim.list_extend(display, sorted)
        return display, #sorted
    end

    local displayer, control_displayer
    if t then
        displayer = t.entry_display.create({
            separator = " ",
            items = {
                { width = 1 },  -- completed icon
                { width = 1 },  -- rank icon
                { width = 5 },  -- rank name
                { width = 1 },  -- warning icon
                { remaining = true },  -- kata name
            },
        })
        control_displayer = t.entry_display.create({
            separator = "",
            items = { { remaining = true } },
        })
    end

    local function combined_entry_maker(item)
        if item._control == "separator" then
            return {
                value = item,
                display = function()
                    return control_displayer({
                        { "──────────────────────────────────────────", "codewars_ref" },
                    })
                end,
                ordinal = "",
            }
        elseif item._control then
            return {
                value = item,
                display = function()
                    return control_displayer({
                        { item.label, "codewars_shortcut" },
                    })
                end,
                ordinal = "",
            }
        end

        local c = kata_columns(item)

        return {
            value = item,
            display = function()
                return displayer({
                    status_icon(c.slug, completed_set),
                    { rank_icon(c.rid), c.hl },
                    { rank_str(c.rname), c.hl },
                    { c.warn_icon, "codewars_error" },
                    { c.display_name },
                })
            end,
            ordinal = ("%s %s %s"):format(c.rname, item.name or "", c.slug),
        }
    end

    local function open_sort_dropdown()
        local sort_entries, default_idx = {}, 1
        for i, mode in ipairs(sort_modes) do
            if has_dates or not mode.dated then
                local prefix = i == current_sort_idx and "● " or "  "
                table.insert(sort_entries, { label = prefix .. mode.label, value = i })
                if i == current_sort_idx then default_idx = #sort_entries end
            end
        end

        dropdown.open({
            prompt_title = "Sort by",
            entries = sort_entries,
            default_idx = default_idx,
            width = 50,
            height = #sort_entries + 4,
            on_select = function(idx)
                current_sort_idx = idx
                save_state("sort")
                vim.schedule(reopen)
            end,
        })
    end

    local function open_lang_dropdown()
        local available = cached_languages
        local lang_entries = {}
        local lang_icons = require("codewars.icons").get()
        local current_lang_idx = 0

        local rank_filtered = slice.filter_by_rank(items, current_rank_filter)
        local all_prefix = current_lang_filter == nil and "● " or "  "
        table.insert(lang_entries, {
            -- value wraps the nil-able lang so on_select can distinguish "All languages"
            value = { lang = nil }, icon = "", icon_hl = "codewars_normal",
            label = ("%sAll languages (%d)"):format(all_prefix, #rank_filtered),
        })
        if current_lang_filter == nil then current_lang_idx = 0 end

        local lang_counts = problemlist_utils.collect_languages(rank_filtered)
        local count_map = {}
        for _, lc in ipairs(lang_counts) do count_map[lc.lang] = lc.count end

        for _, entry in ipairs(available) do
            local count = count_map[entry.lang] or 0
            if count > 0 then
                local prefix = current_lang_filter == entry.lang and "● " or "  "
                if current_lang_filter == entry.lang then current_lang_idx = #lang_entries end
                local icon = lang_icons["lang_" .. entry.lang] or "#"
                table.insert(lang_entries, {
                    value = { lang = entry.lang }, icon = icon,
                    icon_hl = "codewars_lang_" .. entry.lang,
                    label = ("%s%s (%d)"):format(prefix, entry.lang, count),
                })
            end
        end

        dropdown.open({
            prompt_title = "Filter by language",
            entries = lang_entries,
            default_idx = current_lang_idx + 1,
            width = 40,
            height = math.min(#lang_entries + 2, 25),
            on_select = function(v)
                current_lang_filter = v.lang
                save_state("lang")
                vim.schedule(reopen)
            end,
        })
    end

    local function open_rank_dropdown()
        local rank_entries = {}
        local current_rank_idx = 0
        local lang_filtered = problemlist_utils.filter_by_language(items, current_lang_filter)
        -- One pass over the list for every rank's count, not one per rank.
        local per_rank = {}
        for _, item in ipairs(lang_filtered) do
            local r = slice.rank_of(item)
            if r then per_rank[r] = (per_rank[r] or 0) + 1 end
        end
        for j, opt in ipairs(difficulty_options) do
            if current_rank_filter == opt.rank then current_rank_idx = j - 1 end
            local prefix = current_rank_filter == opt.rank and "● " or "  "
            local count = opt.rank and (per_rank[opt.rank] or 0) or #lang_filtered
            table.insert(rank_entries, {
                -- value wraps the nil-able rank so on_select can distinguish "All ranks"
                value = { rank = opt.rank },
                label = ("%s%s (%d)"):format(prefix, opt.label, count),
            })
        end

        dropdown.open({
            prompt_title = "Filter by difficulty",
            entries = rank_entries,
            default_idx = current_rank_idx + 1,
            width = 40,
            height = #rank_entries + 4,
            on_select = function(v)
                current_rank_filter = v.rank
                save_state("rank")
                vim.schedule(reopen)
            end,
        })
    end

    local function make_picker()
        local display = build_display_list()

        local opts = t.themes.get_dropdown({
            layout_config = vim.deepcopy(LIST_LAYOUT),
        })

        local num_controls = 4
        local p = t.pickers.new(opts, {
            prompt_title = ("%s (Default: %s)"):format(title, config.lang),
            finder = t.finders.new_table({
                results = display,
                entry_maker = combined_entry_maker,
            }),
            sorter = t.conf.generic_sorter(opts),
            attach_mappings = function(prompt_bufnr, map)
                t.actions.select_default:replace(function()
                    local selection = t.action_state.get_selected_entry()
                    if not selection then return end

                    if selection.value._control == "sort" then
                        t.actions.close(prompt_bufnr)
                        vim.schedule(open_sort_dropdown)
                        return
                    elseif selection.value._control == "lang" then
                        t.actions.close(prompt_bufnr)
                        vim.schedule(open_lang_dropdown)
                        return
                    elseif selection.value._control == "rank" then
                        t.actions.close(prompt_bufnr)
                        vim.schedule(open_rank_dropdown)
                        return
                    elseif selection.value._control == "separator" then
                        return
                    end

                    t.actions.close(prompt_bufnr)
                    open_kata(selection.value)
                end)

                map("i", "<C-s>", function() t.actions.close(prompt_bufnr); vim.schedule(open_sort_dropdown) end)
                map("n", "<C-s>", function() t.actions.close(prompt_bufnr); vim.schedule(open_sort_dropdown) end)
                map("i", "<C-l>", function() t.actions.close(prompt_bufnr); vim.schedule(open_lang_dropdown) end)
                map("n", "<C-l>", function() t.actions.close(prompt_bufnr); vim.schedule(open_lang_dropdown) end)
                map("i", "<C-d>", function() t.actions.close(prompt_bufnr); vim.schedule(open_rank_dropdown) end)
                map("n", "<C-d>", function() t.actions.close(prompt_bufnr); vim.schedule(open_rank_dropdown) end)

                local function reset_and_reopen()
                    reset_filters()
                    t.actions.close(prompt_bufnr)
                    vim.schedule(reopen)
                end
                map("i", "<C-r>", reset_and_reopen)
                map("n", "<C-r>", reset_and_reopen)

                return true
            end,
        })

        -- Override telescope's status text to subtract control rows from the count
        local orig_get_status_text = p.get_status_text
        p.get_status_text = function(self)
            local text = orig_get_status_text(self)
            return text:gsub("(%d+)%s*/%s*(%d+)", function(a, b)
                return tostring(math.max(0, tonumber(a) - num_controls))
                    .. " / "
                    .. tostring(math.max(0, tonumber(b) - num_controls))
            end)
        end

        return p
    end

    -- vim.ui.select has no custom keys, so sort / language / difficulty /
    -- reset are rows of the list; picking one opens its menu, which reopens
    -- the list. The separator row is telescope decoration only.
    local function show_select()
        local display, count = build_display_list()
        local choices = {}
        for _, item in ipairs(display) do
            if item._control ~= "separator" then table.insert(choices, item) end
        end
        table.insert(choices, 4, { _control = "reset", label = "  Reset filters" })

        vim.ui.select(choices, {
            prompt = ("%s (Default: %s, %d kata)"):format(title, config.lang, count),
            format_item = function(item)
                if item._control then return item.label end
                local c = kata_columns(item)
                return table.concat({
                    status_icon(c.slug, completed_set)[1],
                    rank_icon(c.rid),
                    rank_str(c.rname),
                    c.warn_icon,
                    c.display_name,
                }, " ")
            end,
        }, function(choice)
            if not choice then return end
            if choice._control == "sort" then
                vim.schedule(open_sort_dropdown)
            elseif choice._control == "lang" then
                vim.schedule(open_lang_dropdown)
            elseif choice._control == "rank" then
                vim.schedule(open_rank_dropdown)
            elseif choice._control == "reset" then
                reset_filters()
                vim.schedule(reopen)
            else
                open_kata(choice)
            end
        end)
    end

    reopen = function()
        if use_select then return show_select() end
        make_picker():find()
    end

    reopen()
end

--- Browse all kata. Uses cached problem list for instant loading.
---@param opts? { query?: string, rank?: integer[], sort_key?: string }
--- rank: the requested kyu ranks (negative ids); they become the picker's own
--- rank filter -- one rank or a set -- so Ctrl-d shows what was asked for and
--- can still widen back to "All ranks". sort_key: one of sort_modes' keys.
function picker.problems(opts)
    opts = opts or {}

    -- What this open asks for up front. Only set when actually requested,
    -- so a plain `:CW list` keeps the rank remembered from last time.
    local initial = { sort_key = opts.sort_key }
    if opts.rank and #opts.rank > 0 then
        initial.rank_filter = #opts.rank == 1 and opts.rank[1] or opts.rank
    end

    if opts.query and opts.query ~= "" then
        local search_api = require("codewars.api.search")
        log.info("Searching...")
        search_api.kata(opts, function(results, err)
            if err then return log.err(err) end
            if not results or #results == 0 then return log.warn("No kata found") end

            ensure_completed_set(function(completed_set)
                picker._show_kata_list(results, "Select a Question", completed_set, initial)
            end)
        end)
        return
    end

    local problemlist = require("codewars.cache.problemlist")
    -- A stale list is shown as it is and rebuilt behind the picker; only a
    -- missing one is built in the foreground.
    local cached = problemlist.get()
    problemlist.refresh_if_stale()

    if cached then
        ensure_completed_set(function(completed_set)
            picker._show_kata_list(cached, "Select a Question", completed_set, initial)
        end)
    else
        -- A full build takes minutes. Pressing the key again while it runs
        -- must neither start a second build (twice the request rate, straight
        -- into the limiter) nor queue a second picker for when it ends.
        if picker._awaiting_list then
            local found = problemlist.building()
            return log.info(found
                and ("Still fetching the kata list (%d so far) — the picker opens when it is done"):format(found)
                or "Still fetching the kata list — the picker opens when it is done")
        end
        picker._awaiting_list = true
        problemlist.update(opts, function(items, partial)
            picker._awaiting_list = false
            items = items or {}
            -- Judge emptiness on what the picker will actually show for the
            -- requested ranks, not on the whole (possibly partial) catalogue.
            local shown = slice.filter_by_rank(items, initial.rank_filter or nil)
            if #shown == 0 then
                -- An aborted run already reported its own error.
                if partial then return end
                return log.warn("No kata found")
            end
            if partial then
                -- The list was not cached, so the next open resumes the
                -- build from its last finished rank; but do not pass off
                -- the fragment as the whole catalogue.
                log.warn(("Showing %d kata fetched before the build stopped — run :CW cache update to continue it"):format(#shown))
            end
            ensure_completed_set(function(completed_set)
                picker._show_kata_list(items, "Select a Question", completed_set, initial)
            end)
        end)
    end
end

--- Show enriched kata list (shared by both branches of picker.completed)
local function show_enriched(data, initial)
    local completed_cache = require("codewars.cache.completed")
    completed_cache.enrich(data, function(enriched, err)
        -- The account changed or the cache was cleared: do not show this list.
        if err then return log.warn(tostring(err.msg or "Could not fetch kata details")) end
        vim.schedule(function()
            ensure_completed_set(function(completed_set)
                picker._show_kata_list(enriched, "Select a Question", completed_set, initial)
            end)
        end)
    end)
end

--- Browse completed kata, newest first (the Sort menu can still change it).
function picker.completed()
    local completed_cache = require("codewars.cache.completed")
    local items = completed_cache.get()
    local initial = { sort_key = "recent" }

    if vim.tbl_isempty(items) then
        log.info("Fetching completed kata...")
        completed_cache.update(function(data, err)
            if vim.tbl_isempty(data) then
                if err then
                    -- The refresh failed; an empty list says nothing about
                    -- the account, so do not blame the username.
                    return log.warn("Could not fetch your completed kata: " .. tostring(err.msg or "request failed"))
                end
                return log.warn("No completed kata found. Is your username configured?")
            end
            show_enriched(data, initial)
        end)
    else
        show_enriched(items, initial)
    end
end

local function lang_icon(slug)
    local icons = require("codewars.icons").get()
    return icons["lang_" .. slug] or "#"
end

--- Catalogue kata by slug and by id (a solution file is named after either).
---@return table<string, table>
local function catalogue_index()
    local index = {}
    for _, item in ipairs(require("codewars.cache.problemlist").get() or {}) do
        if item.slug then index[item.slug] = item end
        if item.id then index[item.id] = item end
    end
    return index
end

--- A number that goes up by one each calendar day `time` is later.
local function day_of(time)
    local d = os.date("*t", time)
    return math.floor(os.time({ year = d.year, month = d.month, day = d.day, hour = 12 }) / 86400)
end

--- When `mtime` was, the way a person would say it; a date past a month.
---@param mtime integer
---@param now integer
---@return string
local function when(mtime, now)
    local days = day_of(now) - day_of(mtime)
    if days <= 0 then return "today" end
    if days == 1 then return "yesterday" end
    if days < 7 then return ("%d days ago"):format(days) end
    if days < 30 then
        local weeks = math.floor(days / 7)
        return weeks == 1 and "a week ago" or ("%d weeks ago"):format(weeks)
    end
    return os.date("%Y-%m-%d", mtime)
end

local NOT_CHECKED = "not checked"

--- A file name made readable ("how-old-will-i-be" -> "How old will i be"); an id stays as is.
---@param key string
---@return string
local function readable(key)
    if #key == 24 and key:match("^%x+$") then return key end
    return (key:gsub("-", " "):gsub("^%l", string.upper))
end

--- Kata in the :CW recent history by slug, newest first; a file named by id is not found here.
---@return table<string, cw.RecentEntry>
local function recent_index()
    local index = {}
    for _, e in ipairs(require("codewars.cache.recent").get()) do
        if not index[e.slug] then index[e.slug] = e end
    end
    return index
end

--- What can name a kata the catalogue lacks, in order: its solutions record, the
--- :CW recent history, then details looked up before.
---@class cw.UnfinishedSources
---@field catalogue table<string, table>
---@field recent table<string, cw.RecentEntry>
---@field details table<string, table> cache.completed's kata details; older ones have no name

---@param entry cw.UnfinishedEntry
---@param sources cw.UnfinishedSources
---@return { name: string?, rank_id: integer?, rank_name: string? }
local function known_of(entry, sources)
    local item = sources.catalogue[entry.key] or {}
    local recent = sources.recent[entry.key] or {}
    local looked_up = sources.details[entry.key] or {}
    return {
        name = item.name or entry.name or recent.name or looked_up.name,
        rank_id = item.rank_id or entry.rank_id or recent.rank or (looked_up.rank and looked_up.rank.id),
        rank_name = item.rank_name,
    }
end

---@param entry cw.UnfinishedEntry
---@param sources cw.UnfinishedSources
---@param now integer
local function unfinished_row(entry, sources, now)
    local known = known_of(entry, sources)
    local lang = require("codewars.utils").get_lang(entry.lang)
    return {
        key = entry.key,
        lang = entry.lang,
        file = entry.file,
        name = known.name or readable(entry.key),
        rank_id = known.rank_id,
        -- Left blank rather than "beta" when nothing says what the rank is.
        rank_name = known.rank_name or (known.rank_id and theme.rank_str(known.rank_id)) or "",
        lang_name = lang and lang.lang or entry.lang,
        when = when(entry.mtime, now),
        checked = entry.checked,
    }
end

--- Whether a row lacks a name or rank: nothing knows the kata, or only its rank.
---@param entry cw.UnfinishedEntry
---@param sources cw.UnfinishedSources
local function unnamed(entry, sources)
    local known = known_of(entry, sources)
    return not (known.name and known.rank_id)
end

---@param t table telescope, as picker.dropdown hands it out
---@param rows table[] from unfinished_row
local function open_unfinished(t, rows)
    -- Fixed columns sized to what they hold; the name gets the rest.
    local lang_w, when_w = 0, 0
    for _, row in ipairs(rows) do
        lang_w = math.max(lang_w, vim.fn.strdisplaywidth(row.lang_name))
        when_w = math.max(when_w, vim.fn.strdisplaywidth(row.when))
    end
    -- Rank icon, rank, language icon, separators for the seven columns, window border and padding.
    local fixed = 1 + 5 + 1 + lang_w + when_w + #NOT_CHECKED + 6 + 4
    local displayer = t.entry_display.create({
        separator = " ",
        items = {
            { width = 1 },
            { width = 5 },
            { width = 1 },
            { width = math.max(20, LIST_LAYOUT.width - fixed) },
            { width = lang_w },
            { width = when_w },
            { remaining = true },
        },
    })

    local function entry_maker(row)
        local hl = rank_hl_from_id(row.rank_id)
        return {
            value = row,
            ordinal = ("%s %s %s"):format(row.name, row.lang_name, row.key),
            display = function()
                return displayer({
                    { rank_icon(row.rank_id), hl },
                    { rank_str(row.rank_name), hl },
                    { lang_icon(row.lang), "codewars_lang_" .. row.lang },
                    { row.name },
                    { row.lang_name, "codewars_ref" },
                    { row.when, "codewars_ref" },
                    { row.checked and "" or NOT_CHECKED, "codewars_warning" },
                })
            end,
        }
    end

    local opts = t.themes.get_dropdown({ layout_config = vim.deepcopy(LIST_LAYOUT) })
    local shown = t.pickers.new(opts, {
        prompt_title = ("Unfinished kata (%d)"):format(#rows),
        finder = t.finders.new_table({ results = rows, entry_maker = entry_maker }),
        sorter = t.conf.generic_sorter(opts),
        attach_mappings = function(prompt_bufnr)
            t.actions.select_default:replace(function()
                local selection = t.action_state.get_selected_entry()
                if not selection then return end
                t.actions.close(prompt_bufnr)
                local row = selection.value
                require("codewars-ui.kata"):new(row.key, row.lang, { file = row.file }):mount()
            end)
            return true
        end,
    })
    shown:find()

    local function is_open()
        return shown.prompt_bufnr ~= nil and vim.api.nvim_buf_is_valid(shown.prompt_bufnr)
    end

    --- Redraw with `new_rows`, keeping what was typed, if it is still open.
    ---@param new_rows table[]
    return function(new_rows)
        if not is_open() then return end
        shown:refresh(t.finders.new_table({ results = new_rows, entry_maker = entry_maker }), { reset_prompt = false })
    end, is_open
end

--- The vim.ui.select variant; it cannot redraw, so names found later show next open.
---@param rows table[]
---@return fun(new_rows: table[]) update does nothing: there is no redrawing it
---@return fun(): boolean is_open until a row is chosen or it is cancelled
local function select_unfinished(rows)
    local open = true
    vim.ui.select(rows, {
        prompt = ("Unfinished kata (%d)"):format(#rows),
        format_item = function(row)
            return vim.trim(table.concat({
                rank_icon(row.rank_id), rank_str(row.rank_name), lang_icon(row.lang),
                row.name, row.lang_name, row.when, row.checked and "" or NOT_CHECKED,
            }, " "))
        end,
    }, function(row)
        open = false
        if row then require("codewars-ui.kata"):new(row.key, row.lang, { file = row.file }):mount() end
    end)
    return function() end, function() return open end
end

--- Why :CW unfinished cannot tell which kata are completed, for the user to act on.
---@param err table? from identity.ensure
---@return string
local function unknown_account_message(err)
    if err and err.signed_out then
        return "Sign in with :CW cookie so :CW unfinished can tell your completed kata apart."
    end
    if err and err.auth then
        return "Your Codewars session has expired, so :CW unfinished cannot tell your completed kata apart. "
            .. "Sign in again with :CW cookie."
    end
    return ("Could not detect your username (%s), so :CW unfinished cannot tell your completed kata apart. "
        .. "Open :CW menu to retry, or sign in again with :CW cookie."):format(
        tostring(err and err.msg or "unknown error"))
end

--- ensure_completed_items for :CW unfinished, which judges every file by the list.
--- Only a fully fetched list is trusted (an empty one is real, a marked-only cache
--- is not). Without one, the account is settled first (identity.ensure) to fetch it.
---@param cb fun(items: table[], err: table?)
local function ensure_known_completed_items(cb)
    local _, _, is_fetched = require("codewars.cache.completed").get()
    if is_fetched then
        return ensure_completed_items(cb, { fetched_only = true })
    end
    require("codewars.identity").ensure(function(username, err)
        if not username then return log.warn(unknown_account_message(err)) end
        ensure_completed_items(cb, { fetched_only = true })
    end)
end

--- :CW unfinished. A file seeded before starters were recorded is listed as "not checked".
function picker.unfinished()
    local use_select = dropdown.provider() == "select"
    local t
    if not use_select then
        t = dropdown.telescope()
        if not t then return end
    end
    ensure_known_completed_items(function(completed, err)
        -- With no completed list every file would look unfinished: say what went wrong.
        if err then
            return log.warn(("Could not fetch your completed kata, so :CW unfinished cannot tell which you have "
                .. "finished: %s. Try again."):format(tostring(err.msg or "request failed")))
        end
        local found = require("codewars.unfinished").list(completed)
        if #found == 0 then
            return log.info("Nothing unfinished: every kata you have opened is completed or untouched.")
        end
        local completed_cache = require("codewars.cache.completed")
        local catalogue, recent = catalogue_index(), recent_index()
        --- Read again each time: the details grow as lookups come in.
        local function sources()
            return { catalogue = catalogue, recent = recent, details = completed_cache.get_details() }
        end
        local function rows()
            local known, now = sources(), os.time()
            return vim.tbl_map(function(e) return unfinished_row(e, known, now) end, found)
        end
        local update, is_open
        if use_select then
            update, is_open = select_unfinished(rows())
        else
            update, is_open = open_unfinished(t, rows())
        end
        local function redraw() vim.schedule(function() update(rows()) end) end

        -- Look up unnamed kata and fill them in as Codewars answers, past the first batch too
        -- while the list is open. (vim.ui.select cannot redraw: names show next open.)
        local known = sources()
        local unknown = {}
        for _, e in ipairs(found) do
            if unnamed(e, known) then unknown[#unknown + 1] = { slug = e.key } end
        end
        if #unknown == 0 then return end
        completed_cache.enrich(unknown, redraw, { names = true, keep_going = is_open, on_progress = redraw })
    end)
end

--- Build dropdown entries for a list of language configs.
---@param langs table[] entries from config.langs
---@return cw.picker.DropdownEntry[]
local function lang_dropdown_entries(langs)
    local entries = {}
    for _, lang in ipairs(langs) do
        table.insert(entries, {
            label = lang.lang,
            value = lang,
            icon = lang_icon(lang.slug),
            icon_hl = "codewars_lang_" .. lang.slug,
            ordinal = lang.slug .. " " .. lang.lang,
        })
    end
    return entries
end

--- Focus categories for "Choose Today's Focus" (order matches codewars.com).
--- `key` is the plugin-internal identifier; the server strategy token
--- mapping lives in codewars.api.trainer.
---@type { key: string, label: string, desc: string, icon: string }[]
picker.focus_categories = {
    { key = "fundamentals", label = "Fundamentals", desc = "foundational kata around your rank", icon = "focus_fundamentals" },
    { key = "rank_up", label = "Rank Up", desc = "kata that push you toward your next rank", icon = "focus_rank_up" },
    { key = "practice_and_repeat", label = "Practice and Repeat", desc = "repeat kata you have solved before", icon = "focus_practice_and_repeat" },
    { key = "beta", label = "Beta", desc = "new kata that need feedback", icon = "focus_beta" },
    { key = "random", label = "Random", desc = "any kata, any rank", icon = "random" },
}

--- Pick a focus category (Choose Today's Focus).
---@param cb fun(category_key: string)
function picker.focus_category(cb)
    local icons = require("codewars.icons").get()
    local entries = {}
    for _, cat in ipairs(picker.focus_categories) do
        table.insert(entries, {
            label = ("%-20s %s"):format(cat.label, cat.desc),
            value = cat.key,
            icon = icons[cat.icon] or "#",
            icon_hl = "codewars_icon",
            ordinal = cat.key .. " " .. cat.label,
        })
    end

    dropdown.open({
        prompt_title = "Choose Today's Focus",
        entries = entries,
        width = 70,
        height = #entries + 4,
        on_select = cb,
    })
end

-- Keys/labels mirror api/leaderboard.CATEGORIES (kept literal here so the
-- picker can describe each board without eager-loading the api module).
picker.leaderboard_categories = {
    { key = "overall",  label = "Overall",                      desc = "honor from everything combined",  icon = "leaderboard" },
    { key = "kata",     label = "Completed Kata",               desc = "honor earned by completing kata", icon = "completed" },
    { key = "authored", label = "Authored Kata & Translations", desc = "honor from authoring kata",       icon = "leaderboard_authored" },
    { key = "ranks",    label = "Ranks",                        desc = "total rank score",                icon = "focus_rank_up" },
}

--- Pick a leaderboard category.
---@param cb fun(category_key: string)
function picker.leaderboard_category(cb)
    local icons = require("codewars.icons").get()
    local entries = {}
    for _, cat in ipairs(picker.leaderboard_categories) do
        table.insert(entries, {
            label = ("%-30s %s"):format(cat.label, cat.desc),
            value = cat.key,
            icon = icons[cat.icon] or "#",
            icon_hl = "codewars_icon",
            ordinal = cat.key .. " " .. cat.label,
        })
    end

    dropdown.open({
        prompt_title = "Leaderboard",
        entries = entries,
        width = 70,
        height = #entries + 4,
        on_select = cb,
    })
end

-- Kumite browser: server-paged (5 items/page on the site),
-- page number in the prompt title, language+page persisted across reopens.
local _kumite_lang = nil ---@type string? nil = all languages
local _kumite_page = 1
local _kumite_last = 1
-- Generation guard: rapid page/language changes must not let a slow, stale
-- response open the wrong picker.
local _kumite_gen = 0

---@param iso string? ISO 8601 timestamp
---@return string # compact relative age like "26d" or "7y"
local function kumite_age(iso)
    if type(iso) ~= "string" then return "" end
    local y, mo, d, h, mi = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+)")
    if not y then return "" end
    -- The timestamp is UTC (trailing Z) but os.time reads the fields as
    -- local time; shift by the local offset so ages are not off by it.
    -- Both os.time calls read their fields with the CURRENT DST flag, so the
    -- offset and the target agree even while daylight saving is in effect
    -- (os.date("!*t") reports isdst=false, which would drop an hour).
    local now = os.time()
    local isdst = os.date("*t", now).isdst
    local utc_now = os.date("!*t", now)
    utc_now.isdst = isdst
    local utc_offset = os.difftime(now, os.time(utc_now))
    local then_t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), isdst = isdst }) + utc_offset
    local diff = math.max(0, now - then_t)
    if diff < 3600 then return math.floor(diff / 60) .. "m" end
    if diff < 86400 then return math.floor(diff / 3600) .. "h" end
    if diff < 86400 * 365 then return math.floor(diff / 86400) .. "d" end
    return math.floor(diff / (86400 * 365)) .. "y"
end

--- Open the snippet under the cursor. Signed out, the JSON API is
--- unavailable — fall back to the code-only public view built from list
--- data.
---@param entry cw.KumiteListEntry
---@param entry cw.KumiteListEntry
---@param and_fork boolean? fork the workspace immediately after opening
local function kumite_open_entry(entry, and_fork)
    log.info("Loading kumite…")
    local kumite_api = require("codewars.api.kumite")
    kumite_api.fetch_snippet(entry.id, function(snippet, err)
        if err and err.auth then
            log.info("Signed out — showing the public view from list data. Run :CW cookie for the full view.")
            snippet = kumite_api.snippet_from_list_entry(entry)
        elseif err then
            return log.err(err)
        end
        snippet.forked_from_author = snippet.forked_from_author or entry.forked_from_author
        vim.schedule(function()
            local ws = require("codewars-ui.kumite"):new(snippet):mount()
            -- ws.bufnr is nil when mount() jumped to an already-open tab;
            -- skip the fork there rather than acting on a throwaway object.
            if and_fork and ws.bufnr then
                ws:fork()
            end
        end)
    end)
end

local function kumite_fetch_and_show()
    _kumite_gen = _kumite_gen + 1
    local gen = _kumite_gen
    log.info("Loading kumite…")
    require("codewars.api.kumite").fetch_list(_kumite_lang, _kumite_page, function(result, err)
        if gen ~= _kumite_gen then return end
        if err then return log.err(err) end
        _kumite_page = result.current_page
        _kumite_last = math.max(result.last_page, result.current_page)
        if #result.entries == 0 then
            log.info("No published kumite on this page.")
        end
        vim.schedule(function()
            picker._show_kumite_list(result.entries)
        end)
    end)
end

-- Light-blue floating legend shown alongside the browser so the paging /
-- filter keys are always visible. Non-focusable; the caller closes it when
-- the picker's prompt buffer is wiped.
---@return integer? winid
local function open_kumite_hint()
    -- Two aligned columns: pad the left key/label to a fixed width so the
    -- right column starts at the same offset on every row.
    local rows = {
        { "<CR> view", "<C-f> fork" },
        { "<C-n> next page", "<C-p> prev page" },
        { "<C-g> go to page", "<C-l> language" },
    }
    local left_w = 0
    for _, r in ipairs(rows) do
        left_w = math.max(left_w, #r[1])
    end
    local lines = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = (" %-" .. left_w .. "s   %s"):format(r[1], r[2])
    end

    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, #l + 1)
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
        relative = "editor",
        anchor = "NW",
        row = 1,
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = #lines,
        style = "minimal",
        border = "rounded",
        title = " Kumite browser keys ",
        title_pos = "center",
        focusable = false,
        noautocmd = true,
        zindex = 250, -- above the telescope windows
    })
    if not ok then
        return nil
    end
    vim.wo[win].winhighlight =
        "Normal:codewars_hint,FloatBorder:codewars_hint_border,FloatTitle:codewars_hint_key"
    return win
end

---@param item cw.KumiteListEntry
---@return string
local function kumite_byline(item)
    local byline = item.author or ""
    if item.forked_from_author then
        byline = byline .. " vs " .. item.forked_from_author
    end
    return byline
end

--- Move to a page and refetch. `close` tears down the current picker first;
--- returns false (picker left alone) when the page is out of range or current.
---@param page_num integer
---@param close fun()?
---@return boolean
local function kumite_goto_page(page_num, close)
    if page_num < 1 or page_num > _kumite_last then
        log.info(("Page must be between 1 and %d."):format(_kumite_last))
        return false
    end
    if page_num == _kumite_page then return false end
    _kumite_page = page_num
    if close then close() end
    kumite_fetch_and_show()
    return true
end

local function kumite_pick_language()
    local lang_entries = lang_dropdown_entries(config.langs)
    table.insert(lang_entries, 1, { label = "All languages", value = { slug = false } })
    dropdown.open({
        prompt_title = "Kumite language",
        entries = lang_entries,
        width = 40,
        on_select = function(v)
            _kumite_lang = v.slug or nil
            -- Language switch resets to page 1: a persisted deep
            -- page rarely exists in the new language.
            _kumite_page = 1
            kumite_fetch_and_show()
        end,
    })
end

--- vim.ui.select variant: paging and language are rows of the list. Fork
--- stays available as `:CW kumite fork` in the opened workspace.
---@param entries cw.KumiteListEntry[]
local function show_kumite_select(entries)
    local choices = {}
    if _kumite_page < _kumite_last then
        table.insert(choices, { _control = "next", label = "  Next page" })
    end
    if _kumite_page > 1 then
        table.insert(choices, { _control = "prev", label = "  Prev page" })
    end
    if _kumite_last > 1 then
        table.insert(choices, { _control = "goto", label = "  Go to page..." })
    end
    table.insert(choices, { _control = "lang", label = ("  Language: %s"):format(_kumite_lang or "all") })
    vim.list_extend(choices, entries)

    local function reshow() vim.schedule(function() show_kumite_select(entries) end) end

    vim.ui.select(choices, {
        prompt = ("Kumite · %s · page %d/%d"):format(_kumite_lang or "all", _kumite_page, _kumite_last),
        format_item = function(item)
            if item._control then return item.label end
            return table.concat({
                item.title or "",
                kumite_byline(item),
                item.language or "",
                kumite_age(item.published_at),
            }, "  ")
        end,
    }, function(choice)
        if not choice then return end
        if choice._control == "next" then
            if not kumite_goto_page(_kumite_page + 1) then reshow() end
        elseif choice._control == "prev" then
            if not kumite_goto_page(_kumite_page - 1) then reshow() end
        elseif choice._control == "goto" then
            vim.schedule(function()
                vim.ui.input({ prompt = ("Page (1-%d): "):format(_kumite_last) }, function(input)
                    local n = tonumber(input)
                    if not (n and kumite_goto_page(math.floor(n))) then reshow() end
                end)
            end)
        elseif choice._control == "lang" then
            vim.schedule(kumite_pick_language)
        else
            kumite_open_entry(choice)
        end
    end)
end

---@param entries cw.KumiteListEntry[]
function picker._show_kumite_list(entries)
    if dropdown.provider() == "select" then
        return show_kumite_select(entries)
    end
    local t = dropdown.telescope()
    if not t then return end

    local displayer = t.entry_display.create({
        separator = "  ",
        items = {
            { width = 40 },  -- title
            { width = 26 },  -- author (vs parent-author)
            { width = 12 },  -- language
            { remaining = true },  -- age
        },
    })

    local function entry_maker(item)
        local byline = kumite_byline(item)
        return {
            value = item,
            display = function()
                return displayer({
                    { item.title },
                    { byline, "codewars_ref" },
                    { item.language or "", "codewars_shortcut" },
                    { kumite_age(item.published_at), "codewars_ref" },
                })
            end,
            ordinal = ("%s %s %s"):format(item.title, byline, item.language or ""),
        }
    end

    local function goto_page(prompt_bufnr, page_num)
        kumite_goto_page(page_num, function() t.actions.close(prompt_bufnr) end)
    end

    local hint_win = open_kumite_hint()

    t.pickers.new(t.themes.get_dropdown({ layout_config = { width = 110, height = 14 } }), {
        prompt_title = ("Kumite · %s · page %d/%d"):format(_kumite_lang or "all", _kumite_page, _kumite_last),
        finder = t.finders.new_table({ results = entries, entry_maker = entry_maker }),
        sorter = t.conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            -- The hint box lives and dies with this picker instance (paging /
            -- language switch reopens both).
            vim.api.nvim_create_autocmd("BufWipeout", {
                buffer = prompt_bufnr,
                once = true,
                callback = function()
                    if hint_win and vim.api.nvim_win_is_valid(hint_win) then
                        pcall(vim.api.nvim_win_close, hint_win, true)
                    end
                end,
            })
            t.actions.select_default:replace(function()
                local selection = t.action_state.get_selected_entry()
                if not selection then return end
                t.actions.close(prompt_bufnr)
                kumite_open_entry(selection.value)
            end)

            map({ "i", "n" }, "<C-f>", function()
                local selection = t.action_state.get_selected_entry()
                if not selection then return end
                t.actions.close(prompt_bufnr)
                kumite_open_entry(selection.value, true)
            end)

            map({ "i", "n" }, "<C-n>", function()
                goto_page(prompt_bufnr, _kumite_page + 1)
            end)
            map({ "i", "n" }, "<C-p>", function()
                if _kumite_page <= 1 then return end
                goto_page(prompt_bufnr, _kumite_page - 1)
            end)
            map({ "i", "n" }, "<C-g>", function()
                vim.ui.input({ prompt = ("Page (1-%d): "):format(_kumite_last) }, function(input)
                    local n = tonumber(input)
                    if n then goto_page(prompt_bufnr, math.floor(n)) end
                end)
            end)
            map({ "i", "n" }, "<C-l>", function()
                t.actions.close(prompt_bufnr)
                kumite_pick_language()
            end)
            return true
        end,
    }):find()
end

--- Entry point: browse kumite with persisted language/page state.
function picker.kumite_browse()
    kumite_fetch_and_show()
end

--- Pick a language independent of any mounted kata.
--- Lists every language the plugin supports (config.langs) — the trainer
--- serves rank-appropriate kata per language server-side, so no
--- client-side narrowing to trained languages.
---@param cb fun(lang_slug: string)
function picker.pick_language(cb)
    local default_idx
    for i, lang in ipairs(config.langs) do
        if lang.slug == config.lang then
            default_idx = i
            break
        end
    end

    dropdown.open({
        prompt_title = ("Language (%s)"):format(config.lang),
        entries = lang_dropdown_entries(config.langs),
        default_idx = default_idx,
        width = 40,
        height = 15,
        on_select = function(lang) cb(lang.slug) end,
    })
end

--- Language picker for the KATA AUTHORING editor. Same icon dropdown as
--- training, so picking a language looks the same everywhere, but annotated
--- with which languages the kata already carries versus which one you would
--- be adding.
---
--- Only languages this plugin knows (config.langs) are offered: Codewars lists
--- ~58 in the editor, but the exotic tail has no filetype, no icon and no
--- starter fixture here, so offering them would promise support that does not
--- exist.
---@param opts { current: string, existing: table<string, boolean>, offered: table<string, boolean> }
---@param cb fun(slug: string)
function picker.kata_language(opts, cb)
    local langs = vim.tbl_filter(function(lang)
        return opts.existing[lang.slug] == true or opts.offered[lang.slug] == true
    end, config.langs)

    local entries = lang_dropdown_entries(langs)
    local default_idx
    for i, entry in ipairs(entries) do
        local slug = entry.value.slug
        if slug == opts.current then
            entry.label = entry.label .. "  · editing"
            default_idx = i
        elseif opts.existing[slug] then
            entry.label = entry.label .. "  · in this kata"
        else
            entry.label = entry.label .. "  · add"
        end
    end

    if #entries == 0 then
        return require("codewars.logger").warn("No languages available for this kata.")
    end

    dropdown.open({
        prompt_title = "Kata language",
        entries = entries,
        default_idx = default_idx,
        width = 46,
        height = 15,
        on_select = function(lang)
            cb(lang.slug)
        end,
    })
end

--- Pick a language for the current kata and switch in-place.
---@param kata cw.ui.Kata
function picker.language(kata)
    local langs = config.langs
    if kata.supported_languages and #kata.supported_languages > 0 then
        local supported = {}
        for _, slug in ipairs(kata.supported_languages) do
            supported[slug] = true
        end
        langs = vim.tbl_filter(function(lang)
            return supported[lang.slug]
        end, langs)
    end

    dropdown.open({
        prompt_title = ("Language (%s)"):format(kata.lang),
        entries = lang_dropdown_entries(langs),
        width = 40,
        height = 15,
        on_select = function(lang)
            local new_lang = lang.slug
            config.save_lang(new_lang)
            kata:change_lang(new_lang)
        end,
    })
end

--- What `:CW next` reads: the filters last chosen in the list menus. The
--- picker remembers them so a reopened list looks the way it was left; next
--- borrows the same memory, so "another one" means another of the same.
---@return cw.picker.Selection
function picker.current_filters()
    local mode = sort_modes[_saved_sort_idx or 0]
    return {
        lang = _saved_lang_filter or config.lang,
        rank = _saved_rank_filter,
        sort = mode and mode.key or "shuffle",
    }
end

--- Run `cb` with the completed set, as the list does: fetched first when
--- there is none yet, otherwise served as cached while a stale one refreshes
--- in the background. A kata solved here is marked at once; one solved on
--- the website shows up from the next call after that refresh.
---@param cb fun(completed: table<string, boolean>)
function picker.with_completed(cb)
    ensure_completed_set(cb)
end

return picker
