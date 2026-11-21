local cache_utils = require("codewars.cache.utils")

--- Kata you opened, newest first, one entry per slug + language. Codewars has
--- no "started but not finished" API, so in-progress is this list minus the
--- completed cache.
---@class cw.cache.Recent
local recent = {}

recent.MAX = 50

---@class cw.RecentEntry
---@field slug string
---@field lang string
---@field name string?
---@field rank integer?
---@field opened_at integer os.time()

local function file() return cache_utils.cache_file("recent.json") end

---@return cw.RecentEntry[]
function recent.get()
    local raw = cache_utils.read_json(file())
    if type(raw) ~= "table" or type(raw.items) ~= "table" then return {} end
    return vim.tbl_filter(function(e)
        return type(e) == "table" and type(e.slug) == "string" and type(e.lang) == "string"
    end, raw.items)
end

--- Move (or add) `entry` to the top. Never raises: a broken cache must not
--- stop a kata from opening.
---@param entry { slug: string, lang: string, name: string?, rank: integer? }
function recent.record(entry)
    pcall(function()
        if not (entry and entry.slug and entry.lang) then return end
        local items = { {
            slug = entry.slug,
            lang = entry.lang,
            name = entry.name,
            rank = type(entry.rank) == "number" and entry.rank or nil,
            opened_at = os.time(),
        } }
        for _, e in ipairs(recent.get()) do
            if #items >= recent.MAX then break end
            if not (e.slug == entry.slug and e.lang == entry.lang) then
                table.insert(items, e)
            end
        end
        cache_utils.write_json(file(), { items = items })
    end)
end

return recent
