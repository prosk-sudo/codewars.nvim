local api_utils = require("codewars.api.utils")
local log = require("codewars.logger")

---@class cw.Api.Search
local search = {}

--- Fetch a single page of kata search results.
---
--- `has_more` is false for a page with no result blocks at all: the end of
--- the results. A page that HAS result blocks and parses to none is not
--- that -- the markup moved -- so it comes back as `err` with `err.drift`
--- set, like any other failure to read the page. A page that parses in part
--- keeps what it parsed and says how many blocks it left out in `dropped`.
---@param opts table { language?, query?, rank?, order?, cancelled?: fun(): boolean, retry_rate_limited?: boolean }
---@param page integer
---@param cb function callback(results[], has_more, err?, dropped?: integer)
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
        -- nil keeps the request layer's default (GETs retry a 429); the
        -- cache build passes false because it waits the limiter out itself.
        retry_rate_limited = opts.retry_rate_limited,
        -- plenary's async curl has no timeout of its own. The cache build
        -- is single-flight -- every later :CW list and :CW cache update
        -- joins it -- so one page that never answers would wedge them all
        -- until restart. A timeout fails the page like any other error.
        raw = { "--max-time", "30" },
        callback = function(res, err)
            if err then
                return cb({}, false, err)
            end

            -- The page is HTML, so handle_res hands back the raw body.
            local body = type(res) == "string" and res or ""
            local results, drift, dropped = search.parse_html(body)
            if drift then
                return cb({}, false, drift)
            end

            cb(results, #results > 0, nil, dropped)
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
    local dropped = 0

    -- If no rank filter specified, include all ranks (8 kyu through 1 kyu)
    if not opts.rank then
        opts.rank = { -8, -7, -6, -5, -4, -3, -2, -1 }
    end

    --- One warning for the whole search, not one per page.
    local function finish(err)
        if dropped > 0 then
            log.warn(("%d kata on the search pages could not be read and were left out"
                .. " — the site markup may have changed"):format(dropped))
        end
        cb(all_results, err)
    end

    local function fetch_next()
        if current_page >= max_pages then
            return finish()
        end

        search.fetch_page(opts, current_page, function(results, has_more, err, page_dropped)
            -- Callers already destructure (results, err); dropping it here
            -- turned a rate-limited or expired-session search into a bare
            -- "No kata found", which is the same lie the cache build used
            -- to tell.
            if err then
                return finish(err)
            end

            vim.list_extend(all_results, results)
            dropped = dropped + (page_dropped or 0)

            if has_more and current_page < max_pages - 1 then
                current_page = current_page + 1
                -- Small delay to avoid rate limiting
                vim.defer_fn(fetch_next, 100)
            else
                finish()
            end
        end)
    end

    fetch_next()
end

--- The kata a result link points at. The link is `/kata/<id>`, optionally
--- followed by a path, query or fragment (`/kata/<id>/train/python`); `id`
--- must be a whole 24-hex id, so a slug or a longer or shorter run of hex
--- is not one.
---@param attrs string the attributes of the `<a>`, starting at the space after `a`
---@return string? id
---@return boolean? is_title true when the link goes no deeper than the kata
local function read_kata_link(attrs)
    -- The leading %s keeps `data-href` from passing for `href`.
    local href = attrs:match('%shref%s*=%s*"([^"]*)"') or attrs:match("%shref%s*=%s*'([^']*)'")
    local id, rest = (href or ""):match("^/kata/(" .. api_utils.HEX24 .. ")(.*)$")
    if not id then return nil end
    if rest ~= "" and not rest:find("^[/?#]") then return nil end
    return id, rest:sub(1, 1) ~= "/"
end

--- The id and name of a result block's own title link. A train link
--- (`/kata/<id>/train/python`) is only taken when no plainer link has text,
--- so a "Train" button ahead of the title cannot name the kata; the language
--- icons carry a train link and no text, and are passed over.
---@param block string
---@return string? id
---@return string? name
local function read_title_link(block)
    local deeper_id, deeper_name
    for attrs, text in block:gmatch("<a(%s[^>]*)>([^<]+)</a>") do
        local id, is_title = read_kata_link(attrs)
        local name = text:match("^%s*(.-)%s*$")
        if id and name ~= "" then
            if is_title then return id, name end
            deeper_id, deeper_name = deeper_id or id, deeper_name or name
        end
    end
    return deeper_id, deeper_name
end

--- Parse the search results HTML to extract kata entries.
---
--- Returns the entries it could read, an error when the page has result
--- blocks and NONE of them could be read (`err.drift` is true: the markup
--- changed, which is not the same as a page with no results), and how many
--- blocks it left out. A page with no result blocks at all is simply empty.
---@param html string
---@return table[] results
---@return cw.err? err
---@return integer dropped
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
        local slug, name = read_title_link(block)
        if slug and name then
            entry.id = slug
            entry.slug = slug
            -- Scraped HTML: "Python&#39;s" is how an apostrophe arrives.
            entry.name = require("codewars.api.page").unescape(name)
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

    local dropped = #blocks - #results
    if #blocks > 0 and #results == 0 then
        return results, {
            drift = true,
            blocks = #blocks,
            msg = ("Codewars' search page lists %d kata but none could be read"
                .. " — the site markup may have changed."):format(#blocks),
        }, dropped
    end
    return results, nil, dropped
end

return search
