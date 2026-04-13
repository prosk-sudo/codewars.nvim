local config = require("codewars.config")
local log = require("codewars.logger")
local theme = require("codewars.theme")

---@class cw.Picker
local picker = {}

local _telescope = nil
local function require_telescope()
    if _telescope then return _telescope end

    local ok, pickers = pcall(require, "telescope.pickers")
    if not ok then
        log.error("telescope.nvim is required for the picker")
        return nil
    end

    _telescope = {
        pickers = pickers,
        finders = require("telescope.finders"),
        conf = require("telescope.config").values,
        actions = require("telescope.actions"),
        action_state = require("telescope.actions.state"),
        entry_display = require("telescope.pickers.entry_display"),
        themes = require("telescope.themes"),
    }
    return _telescope
end

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

-- Persistent filter state (remembered across picker reopens)
local _saved_sort_idx = 1
local _saved_lang_filter = config.lang
local _saved_rank_filter = nil

-- Sort modes
local sort_modes = {
    { key = "default", label = "Shuffle" },
    { key = "name", label = "Name (A-Z)" },
    { key = "satisfaction", label = "Satisfaction (%)" },
}

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
    if mode == "default" then return shuffle(items) end
    local sorted = vim.list_slice(items, 1, #items)
    if mode == "name" then
        table.sort(sorted, function(a, b)
            return (a.name or a.slug or "") < (b.name or b.slug or "")
        end)
    elseif mode == "satisfaction" then
        table.sort(sorted, function(a, b)
            return (a.satisfaction or 0) > (b.satisfaction or 0)
        end)
    end
    return sorted
end

--- Show a telescope picker for a list of kata items.
---@param items table[]
---@param title string
---@param completed_set table<string, boolean>
function picker._show_kata_list(items, title, completed_set)
    local t = require_telescope()
    if not t then return end

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

    local current_sort_idx = _saved_sort_idx
    local current_lang_filter = _saved_lang_filter
    local current_rank_filter = _saved_rank_filter
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

        local lang_available = true
        if item.languages and #item.languages > 0 then
            lang_available = vim.tbl_contains(item.languages, config.lang)
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
            table.insert(sort_entries, { _option = true, idx = i, label = prefix .. mode.label })
        end

        local opts = t.themes.get_dropdown({
            layout_config = { width = 50, height = #sort_modes + 4 },
        })

        t.pickers.new(opts, {
            prompt_title = "Sort by",
            default_selection_index = current_sort_idx,
            finder = t.finders.new_table({
                results = sort_entries,
                entry_maker = function(item)
                    return { value = item, display = item.label, ordinal = item.label }
                end,
            }),
            sorter = t.conf.generic_sorter(opts),
            attach_mappings = function(buf)
                t.actions.select_default:replace(function()
                    local sel = t.action_state.get_selected_entry()
                    if sel then current_sort_idx = sel.value.idx; save_state() end
                    t.actions.close(buf)
                    vim.schedule(function() make_picker():find() end)
                end)
                return true
            end,
        }):find()
    end

    local function open_lang_dropdown()
        local available = cached_languages
        local lang_entries = {}
        local lang_icons = require("codewars.icons").get()
        local current_lang_idx = 0

        local rank_filtered = filter_by_rank(items, current_rank_filter)
        local all_prefix = current_lang_filter == nil and "● " or "  "
        table.insert(lang_entries, {
            _option = true, lang = nil, icon = "", icon_hl = "codewars_normal",
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
                    _option = true, lang = entry.lang, icon = icon,
                    icon_hl = "codewars_lang_" .. entry.lang,
                    label = ("%s%s (%d)"):format(prefix, entry.lang, count),
                })
            end
        end

        local lang_displayer = t.entry_display.create({
            separator = " ",
            items = { { width = 2 }, { remaining = true } },
        })

        local opts = t.themes.get_dropdown({
            layout_config = { width = 40, height = math.min(#lang_entries + 2, 25) },
        })

        t.pickers.new(opts, {
            prompt_title = "Filter by language",
            default_selection_index = current_lang_idx + 1,
            finder = t.finders.new_table({
                results = lang_entries,
                entry_maker = function(item)
                    return {
                        value = item,
                        display = function()
                            return lang_displayer({ { item.icon, item.icon_hl }, { item.label } })
                        end,
                        ordinal = item.label,
                    }
                end,
            }),
            sorter = t.conf.generic_sorter(opts),
            attach_mappings = function(buf)
                t.actions.select_default:replace(function()
                    local sel = t.action_state.get_selected_entry()
                    if sel then current_lang_filter = sel.value.lang; save_state() end
                    t.actions.close(buf)
                    vim.schedule(function() make_picker():find() end)
                end)
                return true
            end,
        }):find()
    end

    local function open_rank_dropdown()
        local rank_entries = {}
        local current_rank_idx = 0
        local lang_filtered = problemlist_utils.filter_by_language(items, current_lang_filter)
        for j, opt in ipairs(difficulty_options) do
            if current_rank_filter == opt.rank then current_rank_idx = j - 1 end
            local prefix = current_rank_filter == opt.rank and "● " or "  "
            local count = #filter_by_rank(lang_filtered, opt.rank)
            table.insert(rank_entries, {
                _option = true, rank = opt.rank,
                label = ("%s%s (%d)"):format(prefix, opt.label, count),
            })
        end

        local opts = t.themes.get_dropdown({
            layout_config = { width = 40, height = #rank_entries + 4 },
        })

        t.pickers.new(opts, {
            prompt_title = "Filter by difficulty",
            default_selection_index = current_rank_idx + 1,
            finder = t.finders.new_table({
                results = rank_entries,
                entry_maker = function(item)
                    return { value = item, display = item.label, ordinal = item.label }
                end,
            }),
            sorter = t.conf.generic_sorter(opts),
            attach_mappings = function(buf)
                t.actions.select_default:replace(function()
                    local sel = t.action_state.get_selected_entry()
                    if sel then current_rank_filter = sel.value.rank; save_state() end
                    t.actions.close(buf)
                    vim.schedule(function() make_picker():find() end)
                end)
                return true
            end,
        }):find()
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

    if cached then
        local items = cached
        if opts.rank then
            local rank_set = {}
            for _, r in ipairs(opts.rank) do rank_set[r] = true end
            items = vim.tbl_filter(function(item)
                return item.rank_id and rank_set[item.rank_id]
            end, items)
        end
        ensure_completed_set(function(completed_set)
            picker._show_kata_list(items, "Select a Question", completed_set)
        end)
    else
        problemlist.update(opts, function(items)
            if not items or #items == 0 then
                return log.warn("No kata found")
            end
            ensure_completed_set(function(completed_set)
                picker._show_kata_list(items, "Select a Question", completed_set)
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
        completed_cache.update(function(data)
            if vim.tbl_isempty(data) then
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

--- Pick a language for the current kata and switch in-place.
---@param kata cw.ui.Kata
function picker.language(kata)
    local t = require_telescope()
    if not t then return end

    local displayer = t.entry_display.create({
        separator = " ",
        items = {
            { width = 2 },  -- icon
            { remaining = true }, -- language name
        },
    })

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

    local function entry_maker(lang)
        local icon = lang_icon(lang.slug)
        local hl = "codewars_lang_" .. lang.slug
        return {
            value = lang,
            display = function()
                return displayer({
                    { icon, hl },
                    { lang.lang },
                })
            end,
            ordinal = lang.slug .. " " .. lang.lang,
        }
    end

    local opts = t.themes.get_dropdown({
        layout_config = { width = 40, height = 15 },
    })

    t.pickers.new(opts, {
        prompt_title = ("Language (%s)"):format(kata.lang),
        finder = t.finders.new_table({
            results = langs,
            entry_maker = entry_maker,
        }),
        sorter = t.conf.generic_sorter(opts),
        attach_mappings = function(prompt_bufnr)
            t.actions.select_default:replace(function()
                local selection = t.action_state.get_selected_entry()
                if not selection then return end
                t.actions.close(prompt_bufnr)

                local new_lang = selection.value.slug
                config.save_lang(new_lang)
                kata:change_lang(new_lang)
            end)
            return true
        end,
    }):find()
end

return picker
