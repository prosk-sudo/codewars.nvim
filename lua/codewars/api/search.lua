local api_utils = require("codewars.api.utils")
local log = require("codewars.logger")

---@class cw.Api.Search
local search = {}

--- Fetch a single page of kata search results.
---
--- `has_more` is false for a page with no result blocks. A page with blocks that parses to none
--- is `err` with `err.drift`; a partial parse keeps its results and reports `dropped`.
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

--- A result block: tags `first` to `last` of a page's tag list, and the page text they index
--- into (see api.htmltags). Read from parsed tags and attributes, never by pattern over a tag.
---@class cw.SearchBlock
---@field tags cw.HtmlTag[]
---@field text string
---@field first integer
---@field last integer

--- The kata a title link's href points at: `/kata/<id>` with an optional query or fragment,
--- nothing deeper. `id` must be a whole 24-hex id; `/kata/<id>/train/python` is a button.
---@param href string?
---@return string? id
local function title_id(href)
    local id, rest = (href or ""):match("^/kata/(" .. api_utils.HEX24 .. ")(.*)$")
    if not id then return nil end
    if rest ~= "" and not rest:find("^[?#]") then return nil end
    return id
end

---@param tags cw.HtmlTag[]
---@param from integer
---@param last integer
---@param name string
---@return integer?
local function next_named(tags, from, last, name)
    for i = from + 1, last do
        if tags[i].name == name then return i end
    end
end

--- The text between `tags[from]` and the later `tags[to]`, with the tags left out.
---@param block cw.SearchBlock
---@param from integer
---@param to integer
---@return string
local function visible_text(block, from, to)
    local tags, text = block.tags, block.text
    local parts, at = {}, tags[from].finish + 1
    for i = from + 1, to - 1 do
        parts[#parts + 1] = text:sub(at, tags[i].start - 1)
        at = tags[i].finish + 1
    end
    parts[#parts + 1] = text:sub(at, tags[to].start - 1)
    return table.concat(parts)
end

--- The text of the element opened by `tags[i]`, decoded and trimmed; nil when never closed.
---@param block cw.SearchBlock
---@param i integer
---@return string?
local function element_text(block, i)
    local close = next_named(block.tags, i, block.last, block.tags[i].name)
    if not close or not block.tags[close].close then return nil end
    local unescape = require("codewars.api.page").unescape
    return (unescape(visible_text(block, i, close)):match("^%s*(.-)%s*$"))
end

--- The id and name of a block's title link: the first `<a>` with a plain `/kata/<id>` href and
--- some text (language icons have none). nil when there is none; the block is then dropped.
---@param block cw.SearchBlock
---@return string? id
---@return string? name
local function read_title_link(block)
    for i = block.first, block.last do
        local tag = block.tags[i]
        local id = tag.name == "a" and not tag.close and title_id(tag.attrs.href)
        if id then
            local name = element_text(block, i)
            if name and name ~= "" then return id, name end
        end
    end
end

--- A result's rank, `8 kyu`: the text of the first span that holds nothing else.
---@param block cw.SearchBlock
---@return string?
local function read_rank(block)
    for i = block.first, block.last do
        local tag = block.tags[i]
        if tag.name == "span" and not tag.close then
            local rank = (element_text(block, i) or ""):match("^%d+ %w+$")
            if rank then return rank end
        end
    end
end

---@param block cw.SearchBlock
---@return string[]
local function read_languages(block)
    local languages = {}
    for i = block.first, block.last do
        local language = block.tags[i].attrs["data-language"]
        if language and language ~= "" then languages[#languages + 1] = language end
    end
    return languages
end

local BLOCK_CLASS = "list-item-kata"

--- Whether `tag` opens a result: `list-item-kata` as a whole class name, not `not-list-item-kata`.
---@param tag cw.HtmlTag
---@return boolean
local function opens_block(tag)
    local class = not tag.close and tag.attrs.class
    return class and (" " .. class .. " "):find("%s" .. BLOCK_CLASS:gsub("%-", "%%-") .. "%s") ~= nil
end

--- The tag that closes the element opened by `tags[first]`: where the open/close count of its
--- name returns to zero (void and `<name/>` tags do not count). nil when the page ends first.
---@param tags cw.HtmlTag[]
---@param first integer
---@return integer?
local function closing_tag_of(tags, first)
    local name, depth = tags[first].name, 1
    for i = first + 1, #tags do
        local tag = tags[i]
        if tag.name == name and not tag.empty then
            depth = depth + (tag.close and -1 or 1)
            if depth == 0 then return i end
        end
    end
end

--- Cut a results page into result blocks: each runs from its `list-item-kata` tag to its own
--- closing tag, never to the next result or a fixed length, which could swallow a footer's links.
--- A block with no closing tag is left out, and so is each one after it.
---@param html string
---@return cw.SearchBlock[] blocks
---@return integer unclosed blocks left out
local function split_blocks(html)
    local tags, text = require("codewars.api.htmltags").scan(html)
    local blocks, unclosed, broken = {}, 0, false
    local i = 1
    while i <= #tags do
        local tag = tags[i]
        if not opens_block(tag) then
            i = i + 1
        elseif tag.empty then
            -- No contents, so no title: a block, and an unreadable one.
            blocks[#blocks + 1] = { tags = tags, text = text, first = i, last = i }
            i = i + 1
        elseif broken then
            unclosed, i = unclosed + 1, i + 1
        else
            local last = closing_tag_of(tags, i)
            if last then
                blocks[#blocks + 1] = { tags = tags, text = text, first = i, last = last }
                i = last + 1
            else
                unclosed, broken, i = unclosed + 1, true, i + 1
            end
        end
    end
    return blocks, unclosed
end

--- Parse the search results HTML to extract kata entries.
---
--- Scope: reads Codewars' kata-search markup (see api.htmltags), not general HTML5. A result it
--- cannot read counts as dropped, and a page where none can be read is drift, so a markup
--- change is a warning or an error, never a silently wrong list.
---@param html string
---@return table[] results
---@return cw.err? err `err.drift` when result blocks exist but none could be read
---@return integer dropped result blocks left out
function search.parse_html(html)
    local results = {}

    local blocks, unclosed = split_blocks(html)
    local total = #blocks + unclosed

    for _, block in ipairs(blocks) do
        local entry = {}

        -- Rank
        local rank_name = read_rank(block)
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
            -- Already entity-decoded by read_title_link.
            entry.name = name
        end

        -- Satisfaction from tooltip: 'Satisfaction Rating: 89% of users...'
        -- Read from the block's own text, markup blanked.
        local first, last = block.tags[block.first], block.tags[block.last]
        local sat_pct = block.text:sub(first.start, last.finish):match("Satisfaction Rating: (%d+)%%")
        if sat_pct then
            entry.satisfaction = tonumber(sat_pct)
        end

        -- Supported languages from data-language attributes
        local languages = read_languages(block)
        if #languages > 0 then
            entry.languages = languages
        end

        if entry.slug and entry.name then
            table.insert(results, entry)
        end
    end

    local dropped = total - #results
    if total > 0 and #results == 0 then
        return results, {
            drift = true,
            blocks = total,
            msg = ("Codewars' search page lists %d kata but none could be read"
                .. " — the site markup may have changed."):format(total),
        }, dropped
    end
    return results, nil, dropped
end

return search
