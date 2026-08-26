local config = require("codewars.config")
local log = require("codewars.logger")
local theme = require("codewars.theme")

---@class cw.Picker
local picker = {}

-- Cached completed set (rebuilt per picker session)
local _completed_set = nil
local _completed_set_time = 0

function picker.invalidate_completed_cache()
    _completed_set = nil
    _completed_set_time = 0
end

local function build_completed_set(items)
    local set = {}
    for _, item in ipairs(items) do
        if item.slug then set[item.slug] = true end
        if item.id then set[item.id] = true end
    end
    return set
end

local function get_completed_set()
    local now = os.time()
    if _completed_set and (now - _completed_set_time) < 60 then
        return _completed_set
    end

    local completed_cache = require("codewars.cache.completed")
    local items, _ = completed_cache.get()
    _completed_set = build_completed_set(items)
    _completed_set_time = now
    return _completed_set
end

--- Ensure completed set is populated and fresh.
--- Returns stale data immediately for responsiveness, refreshes in background if stale.
local function ensure_completed_set(cb)
    local completed_cache = require("codewars.cache.completed")
    local items, is_stale = completed_cache.get()
    local set = build_completed_set(items)
    _completed_set = set
    _completed_set_time = os.time()

    if vim.tbl_isempty(set) then
        -- No data at all — must fetch before showing picker
        if config.user.username == "" then return cb(set) end
        log.info("Fetching completed kata...")
        completed_cache.update(function()
            picker.invalidate_completed_cache()
            vim.schedule(function() cb(get_completed_set()) end)
        end)
    elseif is_stale and config.user.username ~= "" then
        -- Have data but stale — show immediately, refresh in background
        cb(set)
        completed_cache.update(function()
            picker.invalidate_completed_cache()
        end)
    else
        cb(set)
    end
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

-- Persistent filter state (remembered across picker reopens)
local _saved_sort_idx = 1
local _saved_lang_filter = config.lang
local _saved_rank_filter = nil

-- Sort modes
local sort_modes = {
    { key = "shuffle", label = "Shuffle" },
    { key = "popularity", label = "Popularity (site order)" },
    { key = "name", label = "Name (A-Z)" },
    { key = "satisfaction", label = "Satisfaction (%)" },
    { key = "hardest", label = "Hardest first" },
    { key = "easiest", label = "Easiest first" },
}

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

--- Filter items by rank.
---@param items table[]
---@param rank integer? nil means all ranks
---@return table[]
local function filter_by_rank(items, rank)
    if not rank then return items end
    return vim.tbl_filter(function(item)
        local rid = item.rank_id or (item.rank and item.rank.id)
        return rid == rank
    end, items)
end

local function shuffle(tbl)
    local shuffled = vim.list_slice(tbl, 1, #tbl)
    for i = #shuffled, 2, -1 do
        local j = math.random(i)
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end
    return shuffled
end

local function sort_items(items, mode)
    if mode == "shuffle" then return shuffle(items) end
    local sorted = vim.list_slice(items, 1, #items)
    if mode == "name" then
        table.sort(sorted, function(a, b)
            return (a.name or a.slug or "") < (b.name or b.slug or "")
        end)
    elseif mode == "satisfaction" then
        table.sort(sorted, function(a, b)
            return (a.satisfaction or 0) > (b.satisfaction or 0)
        end)
    elseif mode == "hardest" or mode == "easiest" then
        -- rank_id is -8 (easiest) .. -1 (hardest); ties keep cache order,
        -- which is the site's popularity order within a rank.
        local sign = mode == "hardest" and -1 or 1
        local pos = {}
        for i, item in ipairs(sorted) do pos[item] = i end
        table.sort(sorted, function(a, b)
            local ra, rb = (a.rank_id or 0) * sign, (b.rank_id or 0) * sign
            if ra ~= rb then return ra < rb end
            return pos[a] < pos[b]
        end)
    end
    -- "popularity": the cache is built rank by rank in the site's
    -- popularity order, so the list as stored already is that order.
    return sorted
end

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
    -- Memoized telescope table lives in picker.dropdown; shared error path.
    local t = dropdown.telescope()
    if not t then return end
    initial = initial or {}

    local displayer = t.entry_display.create({
        separator = " ",
        items = {
            { width = 1 },  -- completed icon
            { width = 1 },  -- rank icon
            { width = 5 },  -- rank name
            { width = 1 },  -- warning icon
            { remaining = true },  -- kata name
        },
    })

    local current_sort_idx = sort_index(initial.sort_key) or _saved_sort_idx
    local current_lang_filter = _saved_lang_filter
    local current_rank_filter = _saved_rank_filter
    if initial.rank_filter ~= nil then
        current_rank_filter = initial.rank_filter or nil
    end
    local make_picker
    local cached_languages = problemlist_utils.collect_languages(items)

    local function save_state()
        _saved_sort_idx = current_sort_idx
        _saved_lang_filter = current_lang_filter
        _saved_rank_filter = current_rank_filter
    end

    local function build_display_list()
        local filtered = problemlist_utils.filter_by_language(items, current_lang_filter)
        filtered = filter_by_rank(filtered, current_rank_filter)
        local sorted = sort_items(filtered, sort_modes[current_sort_idx].key)

        local lang_label = current_lang_filter or "All languages"
        local sort_label = sort_modes[current_sort_idx].label
        local rank_label = "All ranks"
        if current_rank_filter then
            rank_label = math.abs(current_rank_filter) .. " kyu"
        end

        local controls = {
            { _control = "sort", label = ("  Sort: %s"):format(sort_label) },
            { _control = "lang", label = ("  Language: %s"):format(lang_label) },
            { _control = "rank", label = ("  Difficulty: %s (%d)"):format(rank_label, #filtered) },
            { _control = "separator" },
        }

        local display = {}
        vim.list_extend(display, controls)
        vim.list_extend(display, sorted)
        return display, #sorted
    end

    local control_displayer = t.entry_display.create({
        separator = "",
        items = { { remaining = true } },
    })

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

        local rid = item.rank_id or (item.rank and item.rank.id)
        local rname = item.rank_name or (item.rank and item.rank.name) or ""
        local hl = rank_hl_from_id(rid)
        local slug = item.slug or item.id

        -- Judged against the language you are filtering by, not the default:
        -- a kata valid for the selected filter is not "unavailable".
        local lang_available = true
        local judge_lang = current_lang_filter or config.lang
        if item.languages and #item.languages > 0 and judge_lang then
            lang_available = vim.tbl_contains(item.languages, judge_lang)
        end
        local warn_icon = lang_available and " " or "\u{f0205}"

        local display_name = item.name or slug
        if item.satisfaction then
            display_name = ("%s (%d%%)"):format(display_name, item.satisfaction)
        end

        return {
            value = item,
            display = function()
                return displayer({
                    status_icon(slug, completed_set),
                    { rank_icon(rid), hl },
                    { rank_str(rname), hl },
                    { warn_icon, "codewars_error" },
                    { display_name },
                })
            end,
            ordinal = ("%s %s %s"):format(rname, item.name or "", slug),
        }
    end

    local function open_sort_dropdown()
        local sort_entries = {}
        for i, mode in ipairs(sort_modes) do
            local prefix = i == current_sort_idx and "● " or "  "
            table.insert(sort_entries, { label = prefix .. mode.label, value = i })
        end

        dropdown.open({
            prompt_title = "Sort by",
            entries = sort_entries,
            default_idx = current_sort_idx,
            width = 50,
            height = #sort_modes + 4,
            on_select = function(idx)
                current_sort_idx = idx
                save_state()
                vim.schedule(function() make_picker():find() end)
            end,
        })
    end

    local function open_lang_dropdown()
        local available = cached_languages
        local lang_entries = {}
        local lang_icons = require("codewars.icons").get()
        local current_lang_idx = 0

        local rank_filtered = filter_by_rank(items, current_rank_filter)
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
                save_state()
                vim.schedule(function() make_picker():find() end)
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
            if item.rank_id then per_rank[item.rank_id] = (per_rank[item.rank_id] or 0) + 1 end
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
                save_state()
                vim.schedule(function() make_picker():find() end)
            end,
        })
    end

    make_picker = function()
        local display = build_display_list()

        local opts = t.themes.get_dropdown({
            layout_config = { width = 100, height = 0.8 },
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
                    local Kata = require("codewars-ui.kata")
                    local slug = selection.value.slug or selection.value.id
                    local item = selection.value

                    local lang = current_lang_filter
                    if not lang then
                        lang = config.lang
                        if item.languages and #item.languages > 0 and not vim.tbl_contains(item.languages, lang) then
                            lang = item.languages[1]
                        end
                    end

                    Kata:new(slug, lang):mount()
                end)

                map("i", "<C-s>", function() t.actions.close(prompt_bufnr); vim.schedule(open_sort_dropdown) end)
                map("n", "<C-s>", function() t.actions.close(prompt_bufnr); vim.schedule(open_sort_dropdown) end)
                map("i", "<C-l>", function() t.actions.close(prompt_bufnr); vim.schedule(open_lang_dropdown) end)
                map("n", "<C-l>", function() t.actions.close(prompt_bufnr); vim.schedule(open_lang_dropdown) end)
                map("i", "<C-d>", function() t.actions.close(prompt_bufnr); vim.schedule(open_rank_dropdown) end)
                map("n", "<C-d>", function() t.actions.close(prompt_bufnr); vim.schedule(open_rank_dropdown) end)

                local function reset_filters()
                    current_sort_idx = 1
                    current_lang_filter = nil
                    current_rank_filter = nil
                    save_state()
                    t.actions.close(prompt_bufnr)
                    vim.schedule(function() make_picker():find() end)
                end
                map("i", "<C-r>", reset_filters)
                map("n", "<C-r>", reset_filters)

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

    make_picker():find()
end

--- Browse all kata. Uses cached problem list for instant loading.
---@param opts? { query?: string, rank?: integer[], order?: string }
function picker.problems(opts)
    opts = opts or {}

    if opts.query and opts.query ~= "" then
        local search_api = require("codewars.api.search")
        log.info("Searching...")
        search_api.kata(opts, function(results, err)
            if err then return log.err(err) end
            if not results or #results == 0 then return log.warn("No kata found") end

            ensure_completed_set(function(completed_set)
                picker._show_kata_list(results, "Select a Question", completed_set)
            end)
        end)
        return
    end

    local problemlist = require("codewars.cache.problemlist")
    local cached = problemlist.get()

    -- problemlist.update fetches every rank regardless of opts.rank, so the
    -- filter must apply to BOTH branches; it used to apply only to the
    -- cached one, and a fresh build showed all eight ranks.
    -- A single requested rank becomes the picker's OWN rank filter, so its
    -- Ctrl-d menu and counts show exactly what the user asked for; several
    -- ranks are narrowed here and the menu reads "All ranks" over that set.
    -- Either way the remembered filter from a previous open is replaced,
    -- so a stale in-picker choice cannot empty the list just requested.
    local single_rank = opts.rank and #opts.rank == 1 and opts.rank[1] or nil
    local initial = { sort_key = opts.sort_key, rank_filter = single_rank or false }
    local function by_rank(items)
        if not opts.rank or single_rank then return items end
        local rank_set = {}
        for _, r in ipairs(opts.rank) do rank_set[r] = true end
        return vim.tbl_filter(function(item)
            return item.rank_id and rank_set[item.rank_id]
        end, items)
    end

    if cached then
        ensure_completed_set(function(completed_set)
            picker._show_kata_list(by_rank(cached), "Select a Question", completed_set, initial)
        end)
    else
        problemlist.update(opts, function(items, partial)
            items = by_rank(items or {})
            if #items == 0 then
                -- An aborted run already reported its own error.
                if partial then return end
                return log.warn("No kata found")
            end
            if partial then
                -- Nothing was cached, so the next picker open retries; but
                -- do not pass off the fragment as the whole catalogue.
                log.warn(("Showing %d kata fetched before the build was aborted — run :CW cache update to retry"):format(#items))
            end
            ensure_completed_set(function(completed_set)
                picker._show_kata_list(items, "Select a Question", completed_set, initial)
            end)
        end)
    end
end

--- Show enriched kata list (shared by both branches of picker.completed)
local function show_enriched(data)
    local completed_cache = require("codewars.cache.completed")
    completed_cache.enrich(data, function(enriched)
        vim.schedule(function()
            ensure_completed_set(function(completed_set)
                picker._show_kata_list(enriched, "Select a Question", completed_set)
            end)
        end)
    end)
end

--- Browse completed kata.
function picker.completed()
    local completed_cache = require("codewars.cache.completed")
    local items = completed_cache.get()

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
            show_enriched(data)
        end)
    else
        show_enriched(items)
    end
end

local function lang_icon(slug)
    local icons = require("codewars.icons").get()
    return icons["lang_" .. slug] or "#"
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

-- Kumite browser (design §3.2): server-paged (5 items/page on the site),
-- page number in the prompt title, language+page persisted across reopens.
local _kumite_lang = nil ---@type string? nil = all languages
local _kumite_page = 1
local _kumite_last = 1
-- Generation guard: rapid page/language changes must not let a slow, stale
-- response open the wrong picker (eng review D14).
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
--- data (design §3.6).
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

---@param entries cw.KumiteListEntry[]
function picker._show_kumite_list(entries)
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
        local byline = item.author or ""
        if item.forked_from_author then
            byline = byline .. " vs " .. item.forked_from_author
        end
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
        if page_num < 1 or page_num > _kumite_last then
            return log.info(("Page must be between 1 and %d."):format(_kumite_last))
        end
        if page_num == _kumite_page then return end
        _kumite_page = page_num
        t.actions.close(prompt_bufnr)
        kumite_fetch_and_show()
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
                local lang_entries = lang_dropdown_entries(config.langs)
                table.insert(lang_entries, 1, { label = "All languages", value = { slug = false } })
                t.actions.close(prompt_bufnr)
                dropdown.open({
                    prompt_title = "Kumite language",
                    entries = lang_entries,
                    width = 40,
                    on_select = function(v)
                        _kumite_lang = v.slug or nil
                        -- Language switch resets to page 1: a persisted deep
                        -- page rarely exists in the new language (eng D15).
                        _kumite_page = 1
                        kumite_fetch_and_show()
                    end,
                })
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

return picker
