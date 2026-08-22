local api_utils = require("codewars.api.utils")

---@class cw.Api.Search
local search = {}

--- Fetch a single page of kata search results.
---@param opts table { language?, query?, rank?, order?, cancelled?: fun(): boolean }
---@param page integer
---@param cb function callback(results[], has_more, err?)
function search.fetch_page(opts, page, cb)
    local lang = opts.language or require("codewars.config").lang
    local query = opts.query or ""
    local order = opts.order or "popularity+desc"

    local params = {
        ("q=%s"):format(vim.uri_encode(query)),
        "beta=false",
        ("order_by=%s"):format(order),
    }

    if opts.rank then
        for _, r in ipairs(opts.rank) do
            table.insert(params, ("r[]=%d"):format(r))
        end
    end

    if page > 0 then
        table.insert(params, ("page=%d"):format(page))
    end

    local endpoint
    if lang and lang ~= "" then
        endpoint = ("/kata/search/%s?%s"):format(lang, table.concat(params, "&"))
    else
        endpoint = ("/kata/search?%s"):format(table.concat(params, "&"))
    end

    -- Goes through api.utils like every other request, so it gets the same
    -- 429/5xx retry, Retry-After handling and curl-failure reporting. This
    -- used to carry its own copy of the retry loop, which drifted: it
    -- dropped the unparseable-Retry-After signal, could not be cancelled
    -- once the cache build gave up, and reported a refused page as EMPTY,
    -- which reads as "end of this rank" and silently truncated the cache.
    api_utils.get(endpoint, {
        headers = { ["Accept"] = "text/html" },
        cancelled = opts.cancelled,
        callback = function(res, err)
            if err then
                return cb({}, false, err)
            end

            -- The page is HTML, so handle_res hands back the raw body.
            local body = type(res) == "string" and res or ""
            local results = search.parse_html(body)

            cb(results, #results > 0)
        end,
    })
end

--- Search/browse kata by scraping multiple pages.
---@param opts? { language?: string, query?: string, rank?: integer[], order?: string, max_pages?: integer }
---@param cb function callback(results[], err?)
function search.kata(opts, cb)
    opts = opts or {}
    local max_pages = opts.max_pages or 10
    local all_results = {}
    local current_page = 0

    -- If no rank filter specified, include all ranks (8 kyu through 1 kyu)
    if not opts.rank then
        opts.rank = { -8, -7, -6, -5, -4, -3, -2, -1 }
    end

    local function fetch_next()
        if current_page >= max_pages then
            return cb(all_results)
        end

        search.fetch_page(opts, current_page, function(results, has_more, err)
            -- Callers already destructure (results, err); dropping it here
            -- turned a rate-limited or expired-session search into a bare
            -- "No kata found", which is the same lie the cache build used
            -- to tell.
            if err then
                return cb(all_results, err)
            end

            vim.list_extend(all_results, results)

            if has_more and current_page < max_pages - 1 then
                current_page = current_page + 1
                -- Small delay to avoid rate limiting
                vim.defer_fn(fetch_next, 100)
            else
                cb(all_results)
            end
        end)
    end

    fetch_next()
end

--- Parse the search results HTML to extract kata entries.
---@param html string
---@return table[]
function search.parse_html(html)
    local results = {}

    -- Split by list-item-kata blocks
    local blocks = {}
    local pos = 1
    while true do
        local s = html:find("list%-item%-kata", pos)
        if not s then break end
        local e = html:find("list%-item%-kata", s + 20)
        if e then
            table.insert(blocks, html:sub(s, e - 1))
        else
            table.insert(blocks, html:sub(s, math.min(#html, s + 3000)))
        end
        pos = e or #html + 1
    end

    for _, block in ipairs(blocks) do
        local entry = {}

        -- Rank
        local rank_name = block:match("<span>(%d+ %w+)</span>")
        if rank_name then
            entry.rank_name = rank_name
            local num = tonumber(rank_name:match("(%d+)"))
            if rank_name:match("kyu") then
                entry.rank_id = -num
            else
                entry.rank_id = num
            end
        end

        -- Name + slug (ID)
        local slug, name = block:match('<a[^>]*href="/kata/([a-f0-9]+)">([^<]+)</a>')
        if slug and name then
            entry.id = slug
            entry.slug = slug
            entry.name = name:match("^%s*(.-)%s*$")
        end

        -- Satisfaction from tooltip: 'Satisfaction Rating: 89% of users...'
        local sat_pct = block:match("Satisfaction Rating: (%d+)%%")
        if sat_pct then
            entry.satisfaction = tonumber(sat_pct)
        end

        -- Supported languages from data-language attributes
        local languages = {}
        for lang in block:gmatch('data%-language="([^"]+)"') do
            table.insert(languages, lang)
        end
        if #languages > 0 then
            entry.languages = languages
        end

        if entry.slug and entry.name then
            table.insert(results, entry)
        end
    end

    return results
end

return search
