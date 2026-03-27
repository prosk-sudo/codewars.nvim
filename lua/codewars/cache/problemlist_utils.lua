local M = {}

--- Filter items by language.
---@param items table[]
---@param lang string? nil means no filter (all)
---@return table[]
function M.filter_by_language(items, lang)
    if not lang then return items end
    return vim.tbl_filter(function(item)
        -- Items without language data (old cache format) are included
        -- to avoid silently hiding katas after a cache format upgrade
        if not item.languages then return true end
        return vim.tbl_contains(item.languages, lang)
    end, items)
end

--- Collect all unique languages from items, sorted by frequency.
---@param items table[]
---@return table[]
function M.collect_languages(items)
    local counts = {}
    for _, item in ipairs(items) do
        if item.languages then
            for _, lang in ipairs(item.languages) do
                counts[lang] = (counts[lang] or 0) + 1
            end
        end
    end
    local langs = {}
    for lang, count in pairs(counts) do
        table.insert(langs, { lang = lang, count = count })
    end
    table.sort(langs, function(a, b) return a.count > b.count end)
    return langs
end

--- Pick a random kata for a given language from the problem list cache.
---@param lang string
---@return table? item, string? error
function M.random_for_lang(lang)
    local problemlist = require("codewars.cache.problemlist")
    local items = problemlist.get()
    if not items or #items == 0 then
        return nil, "Problem list empty. Run :CW cache update first."
    end

    local filtered = M.filter_by_language(items, lang)
    if #filtered == 0 then
        return nil, ("No kata available for %s"):format(lang)
    end

    return filtered[math.random(#filtered)]
end

return M
