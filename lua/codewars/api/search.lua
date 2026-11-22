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

--- A result block: the tags from its opening tag (`first`) to its closing tag
--- (`last`) in a page's tag list, and the page text they index into, which is
--- the page with what is not markup blanked out (see api.htmltags). Everything
--- read about a result is read from these tags and their parsed attributes, or
--- from the text between them, never by pattern over the text of a tag.
---@class cw.SearchBlock
---@field tags cw.HtmlTag[]
---@field text string
---@field first integer
---@field last integer

--- The kata a title link's href points at: `/kata/<id>`, optionally followed
--- by a query or fragment, and nothing deeper. `id` must be a whole 24-hex id,
--- so a slug or a longer or shorter run of hex is not one. A link with a path
--- after the id (`/kata/<id>/train/python`) is a button, not the title, and
--- is not the kata's name.
---@param href string?
---@return string? id
local function title_id(href)
    local id, rest = (href or ""):match("^/kata/(" .. api_utils.HEX24 .. ")(.*)$")
    if not id then return nil end
    if rest ~= "" and not rest:find("^[?#]") then return nil end
    return id
end

--- The first tag after `from`, up to `last`, named `name` (opening or closing).
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

--- The text between the opening tag `tags[from]` and the later tag `tags[to]`,
--- as it shows: what lies between the tags in them, with the tags left out.
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

--- The text of the element opened by `tags[i]`, up to the closing tag of its
--- own name that follows, entities decoded and the ends trimmed. nil when it
--- is never closed within the block.
---@param block cw.SearchBlock
---@param i integer
---@return string?
local function element_text(block, i)
    local close = next_named(block.tags, i, block.last, block.tags[i].name)
    if not close or not block.tags[close].close then return nil end
    local unescape = require("codewars.api.page").unescape
    return (unescape(visible_text(block, i, close)):match("^%s*(.-)%s*$"))
end

--- The id and name of a result block's own title link: the first real `<a>`
--- whose parsed href is a plain `/kata/<id>` and that has text in it. The name
--- is that text, up to the link's own closing tag: tags inside it
--- (`<a ...><span>Title</span></a>`) are left out, entities decoded and the
--- ends trimmed. Links with no text, the language icons among them, are passed
--- over, and so is one never closed. A block with no such link has no kata in
--- it that we can name, and is left out.
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

--- A result's kyu or dan, `8 kyu`: the text of the first span that holds
--- nothing else.
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

--- The languages a result is offered in: the `data-language` of its tags.
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

--- The class that marks a result's element.
local BLOCK_CLASS = "list-item-kata"

--- Whether `tag` opens a result: a real opening tag with `list-item-kata` as
--- a whole class name, not as part of another (`not-list-item-kata`), and not
--- in some other attribute.
---@param tag cw.HtmlTag
---@return boolean
local function opens_block(tag)
    local class = not tag.close and tag.attrs.class
    return class and (" " .. class .. " "):find("%s" .. BLOCK_CLASS:gsub("%-", "%%-") .. "%s") ~= nil
end

--- Which tag closes the element opened by `tags[first]`: the one that brings
--- the count of that name's open and close tags back to zero. Void elements
--- and `<name/>` have no closing tag, and do not count. nil when the page
--- ends first.
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

--- Cut a results page into its result blocks. A block is the element whose
--- opening tag carries the `list-item-kata` class, from that tag to its own
--- closing tag: not up to the next result, and not a fixed number of
--- characters on, either of which can run past the block into a footer or a
--- related-kata section, whose links would then be read as the result's own.
--- Only real tags count (see api.htmltags): the text of a comment, a script, a
--- template or a quoted attribute value neither opens a block, nor closes
--- one, nor changes how deep it is. The text a block is read from has that
--- text blanked out, so nothing in it is read as a title or a language.
---
--- A block whose closing tag is missing (a cut-off page, broken markup) has no
--- end we could trust, and is left out, never guessed at. Nothing after it
--- can be bounded either, so each block after it is counted as left out
--- without being looked for a close: the tags are read once. Returns the blocks and
--- how many were left out.
---@param html string
---@return cw.SearchBlock[] blocks
---@return integer unclosed
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
--- Scope. This reads Codewars' kata-search markup: real tags, attributes with
--- character references decoded, comments, and the elements whose contents
--- are text (see api.htmltags). It is not a general HTML5 parser. Whatever it
--- cannot read is not guessed at: a result it cannot read counts as dropped,
--- and a page of results it cannot read at all is drift, so that a change in
--- Codewars' markup shows up as a warning or an error, never as a silently
--- wrong list. HTML5 corner cases outside that markup are deliberately out of
--- scope, and fail the same loud way.
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
            -- Already decoded by read_title_link: "Python&#39;s" is how an
            -- apostrophe arrives in the scraped HTML.
            entry.name = name
        end

        -- Satisfaction from tooltip: 'Satisfaction Rating: 89% of users...'.
        -- A phrase in the block's own text (where the tooltip's attribute
        -- value sits), with what is not markup blanked: no tag structure is
        -- read from it.
        local first, last = block.tags[block.first], block.tags[block.last]
        local sat_pct = block.text:sub(first.start, last.finish):match("Satisfaction Rating: (%d+)%%")
        if sat_pct then
            entry.satisfaction = tonumber(sat_pct)
        end

        -- Supported languages from the data-language attribute of its tags
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
