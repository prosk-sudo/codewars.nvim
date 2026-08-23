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
        -- Each entry knows where it came from, so a vote can re-read the
        -- page to reconcile when the server's reply is unusable.
        for _, s in ipairs(result) do
            s.kata_id, s.language = kata_id, language
        end
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
---@field review_id string? the kata review the group belongs to (needed to vote)
---@field code string
---@field authors string[] first few authors, as listed on the page
---@field extra_authors integer how many more solved it identically ("+ 4592")
---@field votes { best_practice: integer, clever: integer }
---@field voted { best_practice: boolean, clever: boolean } the signed-in user's own vote
---@field comments cw.SolutionComment[] flattened tree, depth-first
---@field total_comments integer site's count (includes replies)

--- Marks the start of one solution on the page. Every group wrapper carries
--- it, and unlike a bare id= it cannot collide with the kata's own wrapper.
local GROUP_ANCHOR = 'data%-solution%-group%-group%-id%-value="(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)"'
local REVIEW_ATTR = 'data%-solution%-group%-review%-id%-value="(%x+)"'

solutions.VOTE_LABELS = { "best_practice", "clever" }

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

--- Vote count and the user's own vote for one label ("best_practice" /
--- "clever"). Both are read from INSIDE that label's own <a> element
--- only: the count is its <span>, the vote is the `is-voted` class on the
--- anchor. Bounding the search to the anchor matters — an unbounded scan
--- for "the next <span>" quietly returned the OTHER label's count when
--- this one's markup drifted.
---@param block string
---@param label string
---@return integer count, boolean voted
local function vote_state(block, label)
    local s = block:find('data-label="' .. label .. '"', 1, true)
    if not s then return 0, false end
    local tag_start = block:sub(1, s):match('.*()<a[%s>]') or s
    local tag_end = block:find(">", s, true) or s
    local anchor_end = block:find("</a>", tag_end, true) or tag_end
    local tag = block:sub(tag_start, tag_end)
    local inner = block:sub(tag_end + 1, anchor_end - 1)

    local n = inner:match("<span[^>]*>%s*([%d,]+)%s*</span>")
    local count = n and tonumber((n:gsub(",", ""))) or 0
    local classes = tag:match('class="([^"]*)"') or ""
    return count, classes:find("is%-voted") ~= nil
end

--- Every <pre><code> block in `html`, unescaped and trimmed, in order.
---@param html string
---@return string[]
local function code_blocks(html)
    local codes = {}
    local pos = 1
    while true do
        local pre_s = html:find("<pre", pos, true)
        if not pre_s then break end
        local code_s = html:find("<code", pre_s, true)
        if not code_s then break end
        local code_content_s = html:find(">", code_s, true)
        if not code_content_s then break end
        code_content_s = code_content_s + 1
        local code_e = html:find("</code>", code_content_s, true)
        if not code_e then break end

        local code = page.unescape(html:sub(code_content_s, code_e - 1))
        pos = code_e + 7
        code = code:gsub("^%s+", ""):gsub("%s+$", "")
        if #code > 10 then
            codes[#codes + 1] = code
        end
    end
    return codes
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
                votes = { best_practice = 0, clever = 0 },
                voted = { best_practice = false, clever = false },
                comments = {}, total_comments = 0,
            }
        end
        return result
    end

    for i, p in ipairs(positions) do
        local stop = positions[i + 1] and positions[i + 1].start - 1 or #html
        local block = html:sub(p.start, stop)

        -- The group's code is its FIRST block. Not parse_html: that one
        -- drops the first block when it sees several (the whole-page
        -- fixture rule), which on a slice with a trailing template block
        -- handed back the template instead of the solution.
        local code = code_blocks(block)[1]
        if code then
            local authors = {}
            local users = block:match('solution%-group%-users%-list.-</h6>') or ""
            for name in users:gmatch('href="/users/[^"]*">([^<]+)</a>') do
                authors[#authors + 1] = page.unescape(name)
            end
            local extra = tonumber(users:match("%(%+%s*(%d+)%)")) or 0

            local comments, total = solutions.parse_comments(block)
            local votes, voted = {}, {}
            for _, label in ipairs(solutions.VOTE_LABELS) do
                votes[label], voted[label] = vote_state(block, label)
            end

            result[#result + 1] = {
                id = p.id,
                review_id = block:match(REVIEW_ATTR),
                code = code,
                authors = authors,
                extra_authors = extra,
                votes = votes,
                voted = voted,
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
    local codes = code_blocks(html)

    -- Whole-page rule: block 1 is the test fixture when there are several.
    -- Only valid for a full page without group wrappers; parse() reads
    -- each group's first block directly instead.
    if #codes > 1 then
        table.remove(codes, 1)
    end

    return codes
end

--- Cast or retract a vote on a solution, exactly as the site's own click
--- handler does: POST label_vote/{label} to vote, DELETE the same URL to
--- retract a label that is already voted (POSTing again is idempotent, it
--- does NOT toggle). The reply carries BOTH labels' fresh counts and
--- voted flags and is applied wholesale -- whatever the server decides
--- about the other label (observed live: voting one label cleared the
--- other) is reflected, not assumed. `sol` is updated in place so the
--- popup and the session cache, which hold the same table, stay current.
---@param sol cw.Solution
---@param label "best_practice"|"clever"
---@param cb fun(votes: table?, err: cw.err?, note: string?)
---@param opts? { progress: fun(msg: string) } called when the vote takes a
--- slow path (the page re-read), so the UI can say what it is waiting for
function solutions.vote(sol, label, cb, opts)
    if not vim.tbl_contains(solutions.VOTE_LABELS, label) then
        return cb(nil, { msg = "Unknown vote label: " .. tostring(label) })
    end
    if not sol.review_id or sol.review_id == "" or not sol.id or sol.id == "" then
        return cb(nil, { msg = "This solution cannot be voted on from here (no review/group id on the page)." })
    end

    local endpoint = ("/kata/reviews/%s/groups/%s/label_vote/%s"):format(sol.review_id, sol.id, label)
    local api_utils = require("codewars.api.utils")
    local method = (sol.voted and sol.voted[label]) and api_utils.delete or api_utils.post
    method(endpoint, {
        callback = function(res, err)
            if err then
                return cb(nil, err)
            end
            if type(res) ~= "table" or not res.success or type(res.votes) ~= "table" then
                if opts and opts.progress then
                    opts.progress("Codewars did not confirm the vote; re-reading the page…")
                end
                return solutions.reconcile_vote(sol, res, cb)
            end
            solutions.apply_votes(sol, res.votes)
            cb(res.votes)
        end,
    })
end

--- Copy a label_vote reply's counts and flags onto the solution.
---@param sol cw.Solution
---@param votes table { best_practice = { count, voted }, clever = { count, voted } }
function solutions.apply_votes(sol, votes)
    for _, l in ipairs(solutions.VOTE_LABELS) do
        local v = votes[l]
        if type(v) == "table" then
            sol.votes[l] = tonumber(v.count) or sol.votes[l]
            sol.voted[l] = v.voted == true
        end
    end
end

--- The server answered the vote with `success = false`. Seen live on the
--- most-solved kata: its worker RECORDS the vote, then times out
--- recounting ("Request ran for longer than 15000ms") and replies with
--- an error body over HTTP 200. Re-POSTing would time out again, so
--- instead re-read the page (bypassing the cache) and take the group's
--- real state from there; the caller gets the votes plus a note saying
--- the reply had to be reconciled. Only if that also fails is the
--- server's message reported as the error.
---@param sol cw.Solution
---@param res any the unusable reply
---@param cb fun(votes: table?, err: cw.err?, note: string?)
function solutions.reconcile_vote(sol, res, cb)
    local server_msg = type(res) == "table" and res.message or vim.inspect(res)
    if not sol.kata_id or not sol.language then
        return cb(nil, { msg = "Codewars did not accept the vote: " .. tostring(server_msg) })
    end
    solutions.fetch(sol.kata_id, sol.language, function(items, err)
        local fresh
        for _, s in ipairs(items or {}) do
            if s.id == sol.id then fresh = s break end
        end
        if err or not fresh then
            return cb(nil, { msg = ("Codewars did not confirm the vote (%s), and re-reading the page failed%s")
                :format(tostring(server_msg), err and (": " .. (err.msg or "")) or "") })
        end
        sol.votes, sol.voted = fresh.votes, fresh.voted
        local votes = {}
        for _, l in ipairs(solutions.VOTE_LABELS) do
            votes[l] = { count = fresh.votes[l], voted = fresh.voted[l] }
        end
        cb(votes, nil, ("Codewars timed out answering (%s); re-read the page instead"):format(tostring(server_msg)))
    end, { force = true })
end

return solutions
