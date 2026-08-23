local urls = require("codewars.api.urls")
local page = require("codewars.api.page")
local log = require("codewars.logger")

---@class cw.Api.Solutions
local solutions = {}

--- Fetch community solutions for a completed kata.
---@param kata_id string
---@param language string
---@param cb function callback(solutions_list?)
---@param opts? { unranked: boolean } unranked (beta) kata have no public solutions until approved
function solutions.fetch(kata_id, language, cb, opts)
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

        local result = solutions.parse_html(body, language)
        if #result == 0 then
            local level, msg = solutions.empty_reason(body, opts and opts.unranked)
            log[level](msg)
        end
        cb(result)
    end)
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
