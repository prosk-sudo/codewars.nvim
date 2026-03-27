local urls = require("codewars.api.urls")
local headers_mod = require("codewars.api.headers")
local log = require("codewars.logger")

---@class cw.Api.Solutions
local solutions = {}

--- Fetch community solutions for a completed kata.
---@param kata_id string
---@param language string
---@param cb function callback(solutions_list?)
function solutions.fetch(kata_id, language, cb)
    local url = ("%s/kata/%s/solutions/%s"):format(urls.base, kata_id, language)
    local hdrs = headers_mod.get()

    local header_args = {}
    for k, v in pairs(hdrs) do
        table.insert(header_args, "-H")
        table.insert(header_args, k .. ": " .. v)
    end

    -- Write to temp file to preserve newlines exactly
    local tmp = vim.fn.tempname()

    local cmd = vim.list_extend({
        "curl", "-s", "-L",
        "-o", tmp,
        url,
        "--max-time", "15",
    }, header_args)

    vim.fn.jobstart(cmd, {
        on_exit = vim.schedule_wrap(function(_, exit_code)
            local body = ""
            local f = io.open(tmp, "r")
            if f then
                body = f:read("*a")
                f:close()
            end
            pcall(os.remove, tmp)

            if exit_code ~= 0 then
                return cb(nil, { msg = "Failed to fetch solutions (curl error)" })
            end

            if body == "" then
                return cb(nil, { msg = "Empty response when fetching solutions. Your session may have expired." })
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
                log.warn("Could not parse solutions from page. Codewars may have changed their HTML format.")
            end
            cb(result)
        end),
    })
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

        -- Unescape HTML entities
        code = code:gsub("&lt;", "<")
        code = code:gsub("&gt;", ">")
        code = code:gsub("&amp;", "&")
        code = code:gsub("&quot;", '"')
        code = code:gsub("&#39;", "'")
        code = code:gsub("&#x27;", "'")
        code = code:gsub("&#x2F;", "/")
        code = code:gsub("&nbsp;", " ")

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
