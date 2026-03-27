local curl = require("plenary.curl")
local urls = require("codewars.api.urls")
local headers_mod = require("codewars.api.headers")

---@class cw.Api.Search
local search = {}

--- Fetch a single page of kata search results.
---@param opts table
---@param page integer
---@param cb function callback(results[], has_more)
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

    local url
    if lang and lang ~= "" then
        url = ("%s/kata/search/%s?%s"):format(urls.base, lang, table.concat(params, "&"))
    else
        url = ("%s/kata/search?%s"):format(urls.base, table.concat(params, "&"))
    end
    local hdrs = headers_mod.get()
    hdrs["Accept"] = "text/html"

    curl.get(url, {
        headers = hdrs,
        compressed = false,
        callback = vim.schedule_wrap(function(out)
            if out.exit ~= 0 or out.status >= 300 then
                local err = { msg = "Failed to search kata" }
                if out.status == 401 or out.status == 403 then
                    err = { msg = "Session expired or invalid. Run :CW cookie to re-authenticate.", auth = true }
                end
                return cb({}, false, err)
            end

            local body = out.body or ""
            local results = search.parse_html(body)

            cb(results, #results > 0)
        end),
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

        search.fetch_page(opts, current_page, function(results, has_more)
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
