local urls = require("codewars.api.urls")
local page = require("codewars.api.page")

---@class cw.Api.Leaderboard
local leaderboard = {}

---@class cw.LeaderboardEntry
---@field position integer
---@field username string
---@field rank string? display rank like "4 kyu" or "1 dan"
---@field clan string? nil when the user has no clan
---@field honor string formatted number ("487,855"); rank score on the ranks board

--- Stable display order for the menu and picker. value_label is the
--- column header codewars.com uses for the numeric column.
leaderboard.CATEGORIES = {
    { key = "overall",  label = "Overall",                      path = "",          value_label = "Honor" },
    { key = "kata",     label = "Completed Kata",               path = "/kata",     value_label = "Honor" },
    { key = "authored", label = "Authored Kata & Translations", path = "/authored", value_label = "Honor" },
    { key = "ranks",    label = "Ranks",                        path = "/ranks",    value_label = "Score" },
}

---@param key string?
---@return table? category
function leaderboard.category(key)
    for _, cat in ipairs(leaderboard.CATEGORIES) do
        if cat.key == key then
            return cat
        end
    end
end

local ENTITIES = {
    ["&lt;"] = "<",
    ["&gt;"] = ">",
    ["&amp;"] = "&",
    ["&quot;"] = '"',
    ["&#39;"] = "'",
    ["&#x27;"] = "'",
    ["&#x2F;"] = "/",
    ["&nbsp;"] = " ",
}

local function unescape(s)
    return (s:gsub("&[#%w]+;", ENTITIES))
end

local function strip_tags(s)
    return (s:gsub("<[^>]->", ""))
end

--- Parse a leaderboard page into entries. All four category pages share
--- one table layout: Position | User (rank badge + name) | Clan | Honor.
--- Clan is empty for most users; "None" is a real clan name, not a
--- placeholder, so only a blank cell maps to nil.
---@param html string
---@return cw.LeaderboardEntry[]
function leaderboard.parse_html(html)
    local entries = {}
    for username, row in html:gmatch('<tr data%-username="([^"]*)">(.-)</tr>') do
        local tds = {}
        for td in row:gmatch("<td[^>]*>(.-)</td>") do
            tds[#tds + 1] = td
        end

        local position = tds[1] and tonumber(tds[1]:match("#(%d+)") or "")
        if position and #tds >= 4 then
            local clan = vim.trim(unescape(strip_tags(tds[3])))
            entries[#entries + 1] = {
                position = position,
                username = unescape(username),
                rank = tds[2]:match("<span>([^<]+)</span>"),
                clan = clan ~= "" and clan or nil,
                honor = vim.trim(strip_tags(tds[4])),
            }
        end
    end
    return entries
end

--- Numeric rank id for theme coloring: "4 kyu" → -4, "1 dan" → 1.
---@param rank_str string?
---@return integer?
function leaderboard.rank_id(rank_str)
    if type(rank_str) ~= "string" then
        return nil
    end
    local kyu = rank_str:match("^(%d+) kyu$")
    if kyu then
        return -tonumber(kyu)
    end
    local dan = rank_str:match("^(%d+) dan$")
    if dan then
        return tonumber(dan)
    end
    return nil
end

--- Fetch the top-500 leaderboard for a category.
---@param category_key string one of the CATEGORIES keys
---@param cb fun(entries: cw.LeaderboardEntry[]?, err: cw.err?)
function leaderboard.fetch(category_key, cb)
    local cat = leaderboard.category(category_key)
    if not cat then
        return cb(nil, { msg = ("Unknown leaderboard category: %s"):format(tostring(category_key)) })
    end

    page.fetch(urls.base .. "/users/leaderboard" .. cat.path, function(body, perr)
        if perr then
            return cb(nil, { msg = perr.curl and "Failed to fetch the leaderboard (curl error)"
                or "Empty response when fetching the leaderboard." })
        end

        local entries = leaderboard.parse_html(body)
        if #entries == 0 then
            return cb(nil, { msg = "Could not parse the leaderboard page. Codewars may have changed their HTML format." })
        end
        cb(entries)
    end)
end

return leaderboard
