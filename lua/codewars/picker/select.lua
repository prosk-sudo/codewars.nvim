--- The selection the kata list shows -- a language filter, a rank filter,
--- then a sort -- as plain functions over the cached catalogue.
---
--- Lifted out of the telescope picker so `:CW next` can take the first entry
--- without opening a UI, and so the two cannot drift: whatever the list would
--- show first is what next opens. Pure on purpose -- no telescope, no state,
--- nothing read from disk. The picker remembers the chosen filters; this
--- module owns what they mean.
local M = {}

---@param item table a catalogue entry
---@return integer? rank id, -8 (easiest) .. -1 (hardest); nil for unranked (beta)
function M.rank_of(item)
    return item.rank_id or (item.rank and item.rank.id)
end

--- `rank` is nil (all), one rank, or a list of ranks (`:CW list
--- difficulty=8,7`). Unranked kata only pass when no rank is asked for.
---@param items table[]
---@param rank integer|integer[]|nil
---@return table[]
function M.filter_by_rank(items, rank)
    if not rank then return items end
    local wanted = type(rank) == "table" and rank or { rank }
    local set = {}
    for _, r in ipairs(wanted) do set[r] = true end
    return vim.tbl_filter(function(item)
        return set[M.rank_of(item)] == true
    end, items)
end

---@param rank integer|integer[]|nil
---@return string
function M.rank_label(rank)
    if not rank then return "All ranks" end
    local ranks = type(rank) == "table" and rank or { rank }
    return table.concat(vim.tbl_map(function(r) return tostring(math.abs(r)) end, ranks), ",") .. " kyu"
end

--- A shuffled copy; the input is left in cache order.
local function shuffle(tbl)
    local shuffled = vim.list_slice(tbl, 1, #tbl)
    for i = #shuffled, 2, -1 do
        local j = math.random(i)
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end
    return shuffled
end

--- A sorted copy. `mode` is a key of picker.sort_modes.
---@param items table[]
---@param mode string
---@return table[]
function M.sort_items(items, mode)
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
            -- Unranked (beta) kata go last either way.
            local ra, rb = M.rank_of(a), M.rank_of(b)
            if (ra == nil) ~= (rb == nil) then return rb == nil end
            ra, rb = (ra or 0) * sign, (rb or 0) * sign
            if ra ~= rb then return ra < rb end
            return pos[a] < pos[b]
        end)
    end
    return sorted
end

---@class cw.picker.Selection
---@field lang string
---@field rank integer|integer[]|nil
---@field sort string a key of picker.sort_modes

--- The first kata the list would show for `sel` that is not in `skip`, or
--- nil when every kata in that slice is.
---@param items table[] the cached catalogue
---@param sel cw.picker.Selection
---@param skip table<string, boolean> slugs and ids to pass over (solved, or already open)
---@return table? item
function M.next(items, sel, skip)
    local pool = require("codewars.cache.problemlist_utils").filter_by_language(items, sel.lang)
    pool = M.filter_by_rank(pool, sel.rank)
    for _, item in ipairs(M.sort_items(pool, sel.sort or "shuffle")) do
        if not (skip[item.slug] or skip[item.id]) then
            return item
        end
    end
    return nil
end

return M
