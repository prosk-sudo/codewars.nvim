local urls = require("codewars.api.urls")
local page = require("codewars.api.page")
local log = require("codewars.logger")

---@class cw.Api.Solutions
local solutions = {}

--- Parsed pages kept for the session. Codewars renders every comment
--- server-side and takes 5-7 s to answer for a popular kata (measured:
--- time-to-first-byte, not transfer), so a second `:CW solutions` on the
--- same kata should not pay that again. Votes and comments can go stale
--- within the window; it is short enough that this is acceptable, and a
--- vote cast from the plugin updates the entry directly.
---@type table<string, { at: integer, items: cw.Solution[] }>
solutions._cache = {}
solutions.CACHE_TTL_S = 10 * 60

local function cache_key(kata_id, language)
    return kata_id .. "/" .. language
end

--- Drop a cached page (or all of them).
---@param kata_id string?
---@param language string?
function solutions.invalidate(kata_id, language)
    if kata_id then
        solutions._cache[cache_key(kata_id, language or "")] = nil
    else
        solutions._cache = {}
    end
end

--- Fetch community solutions for a completed kata.
---@param kata_id string
---@param language string
---@param cb function callback(solutions_list?, err?)
---@param opts? { unranked: boolean, force: boolean } unranked (beta) kata have
--- no public solutions until approved; force bypasses the session cache
function solutions.fetch(kata_id, language, cb, opts)
    local key = cache_key(kata_id, language)
    local hit = solutions._cache[key]
    if hit and not (opts and opts.force) and os.time() - hit.at < solutions.CACHE_TTL_S then
        return cb(hit.items)
    end

    local url = ("%s/kata/%s/solutions/%s"):format(urls.base, kata_id, language)

    page.fetch(url, function(body, perr)
        if perr then
            -- An HTTP-status error (429 / 403 / 5xx) already says what
            -- happened and carries the auth / rate_limited flags; only the
            -- transport and empty-body cases need solution-specific words.
            if perr.status then
                return cb(nil, perr)
            end
            return cb(nil, { msg = perr.curl and "Failed to fetch solutions (curl error)"
                or "Empty response when fetching solutions. Your session may have expired." })
        end

        -- Detect login page redirect (expired session)
        if body:match("^<!DOCTYPE") or body:match("^<html") then
            local has_code = body:find("<pre") and body:find("<code")
            if not has_code then
                return cb(nil, { msg = "Session expired or invalid. Run :CW cookie to re-authenticate.", auth = true })
            end
        end

        local result = solutions.parse(body, language)
        if #result == 0 then
            local level, msg = solutions.empty_reason(body, opts and opts.unranked)
            log[level](msg)
        else
            -- Only a page that actually yielded solutions is worth keeping;
            -- an empty or locked page should be retried next time.
            solutions._cache[key] = { at = os.time(), items = result }
        end
        cb(result)
    end)
end

---@class cw.SolutionComment
---@field id string
---@field author string
---@field rank string? e.g. "1 kyu"
---@field body string raw markdown
---@field created string? ISO-8601 date part, e.g. "2026-06-05"
---@field score integer comment up/down vote score
---@field depth integer 0 for top-level, 1+ for replies
---@field masked boolean spoiler-flagged on the site

---@class cw.Solution
---@field id string solution group id
---@field code string
---@field authors string[] first few authors, as listed on the page
---@field extra_authors integer how many more solved it identically ("+ 4592")
---@field votes { best_practice: integer, clever: integer }
---@field comments cw.SolutionComment[] flattened tree, depth-first
---@field total_comments integer site's count (includes replies)

--- Marks the start of one solution on the page. Every group wrapper carries
--- it, and unlike a bare id= it cannot collide with the kata's own wrapper.
local GROUP_ANCHOR = 'data%-solution%-group%-group%-id%-value="(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)"'

--- Flatten the site's nested comment tree, depth-first, so the UI can
--- render it top to bottom with indentation.
---@param list table[]
---@param depth integer
---@param out cw.SolutionComment[]
local function flatten_comments(list, depth, out)
    for _, c in ipairs(list or {}) do
        if type(c) == "table" then
            local user = type(c.user) == "table" and c.user or {}
            local created = type(c.created_at_datetime) == "string" and c.created_at_datetime:match("^(%d%d%d%d%-%d%d%-%d%d)") or nil
            out[#out + 1] = {
                id = tostring(c.id or ""),
                author = tostring(user.username or "?"),
                rank = user.rank_name,
                body = type(c.markdown) == "string" and c.markdown or "",
                created = created,
                score = tonumber(c.votes_score) or 0,
                depth = depth,
                masked = c.masked == true,
            }
            flatten_comments(c.comments, depth + 1, out)
        end
    end
end

--- Parse the comments component's embedded JSON. The site ships every
--- solution's comments inline (HTML-escaped in a data attribute), so no
--- second request is needed.
---@param block string one solution's HTML
---@return cw.SolutionComment[], integer total
function solutions.parse_comments(block)
    local raw = block:match('data%-view%-data="(.-)"')
    if not raw then return {}, 0 end
    local ok, data = require("codewars.api.utils").decode_json(page.unescape(raw))
    if not ok or type(data) ~= "table" then return {}, 0 end
    local out = {}
    flatten_comments(data.comments, 0, out)
    return out, tonumber(data.totalComments) or #out
end

--- Vote count for one label ("best_practice" / "clever"). The count is the
--- <span> right after the label inside the vote-labels list.
---@param block string
---@param label string
---@return integer
local function vote_count(block, label)
    local s = block:find('data%-label="' .. label .. '"')
    if not s then return 0 end
    local n = block:match("<span>(%d+)</span>", s)
    return tonumber(n) or 0
end

--- Parse the solutions page into structured entries: code plus authors,
--- Best Practices / Clever counts and comments. Falls back to the bare
--- code-block scan when the page has no group wrappers (older fixtures,
--- the beta "no solutions" template), so callers always get a list.
---@param html string
---@param language string
---@return cw.Solution[]
function solutions.parse(html, language)
    local result = {}
    local positions = {}
    local pos = 1
    while true do
        local s, e, id = html:find(GROUP_ANCHOR, pos)
        if not s then break end
        positions[#positions + 1] = { start = s, id = id }
        pos = e + 1
    end

    if #positions == 0 then
        for _, code in ipairs(solutions.parse_html(html, language)) do
            result[#result + 1] = {
                id = "", code = code, authors = {}, extra_authors = 0,
                votes = { best_practice = 0, clever = 0 }, comments = {}, total_comments = 0,
            }
        end
        return result
    end

    for i, p in ipairs(positions) do
        local stop = positions[i + 1] and positions[i + 1].start - 1 or #html
        local block = html:sub(p.start, stop)

        local codes = solutions.parse_html(block, language)
        local code = codes[1]
        if code then
            local authors = {}
            local users = block:match('solution%-group%-users%-list.-</h6>') or ""
            for name in users:gmatch('href="/users/[^"]*">([^<]+)</a>') do
                authors[#authors + 1] = page.unescape(name)
            end
            local extra = tonumber(users:match("%(%+%s*(%d+)%)")) or 0

            local comments, total = solutions.parse_comments(block)

            result[#result + 1] = {
                id = p.id,
                code = code,
                authors = authors,
                extra_authors = extra,
                votes = {
                    best_practice = vote_count(block, "best_practice"),
                    clever = vote_count(block, "clever"),
                },
                comments = comments,
                total_comments = total,
            }
        end
    end

    return result
end

--- Explain why a solutions page yielded zero parsed solutions.
---@param body string the fetched page HTML
---@param unranked boolean? caller knows the kata is beta/unranked
---@return "info"|"warn" level, string msg
function solutions.empty_reason(body, unranked)
    if unranked then
        -- Canonical signal from the caller's kata data: beta kata ship no
        -- server-rendered solutions until approved.
        return "info", "No community solutions for this kata yet (beta kata show solutions after approval)."
    end
    -- Locked variant: the site offers "Unlock Solutions (Forfeit ...)" when
    -- it has no registered completion of this kata for the account.
    if body:find("[Ff]orfeit") then
        return "warn", "Solutions are locked — codewars.com has not registered a completion of this kata on your account."
    end
    if body:find('v%-text="solution"') then
        -- Page rendered its empty Vue template — no solutions, not drift.
        return "info", "No community solutions for this kata yet."
    end
    return "warn", "Could not parse solutions from page. Codewars may have changed their HTML format."
end

--- Parse solutions HTML to extract code blocks.
---@param html string
---@param language string
---@return string[]
function solutions.parse_html(html, language)
    local codes = {}

    local pos = 1
    while true do
        local pre_s = html:find("<pre", pos)
        if not pre_s then break end
        local code_s = html:find("<code", pre_s)
        if not code_s then break end
        local code_content_s = html:find(">", code_s)
        if not code_content_s then break end
        code_content_s = code_content_s + 1
        local code_e = html:find("</code>", code_content_s)
        if not code_e then break end

        local code = html:sub(code_content_s, code_e - 1)
        pos = code_e + 7

        code = page.unescape(code)

        -- Trim
        code = code:gsub("^%s+", ""):gsub("%s+$", "")

        if #code > 10 then
            table.insert(codes, code)
        end
    end

    -- Skip block 1 (test fixture) if we have multiple
    if #codes > 1 then
        table.remove(codes, 1)
    end

    return codes
end

return solutions
