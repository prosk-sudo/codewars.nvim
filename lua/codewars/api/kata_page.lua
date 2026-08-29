local page = require("codewars.api.page")

--- Kata editor LOAD (contract live-captured 2026-07-25 from
--- `/kata/{id}/edit/{lang}`). The editor ships its model in two places:
---
---   * the code + per-language ids live in an embedded JS blob,
---     `App.setup({ … data: JSON.parse("<json>") … })`, whose language fields
---     (answer/setup/fixture/example_fixture/package) are PERCENT-ENCODED;
---   * the kata metadata (name/discipline/rank/tags/contributors/description)
---     lives in ordinary `code_challenge[...]` form controls, each carrying a
---     stable `id="code_challenge_<field>"`.
---
--- Both are parsed here so the workspace opens with exactly what the website
--- would show. Attribute ORDER varies between controls on the real page, so
--- every lookup finds the tag by id first and reads attributes out of it —
--- never a fixed `id=…value=…` sequence.
---@class cw.Api.KataPage
local kata_page = {}

local HEX24 = require("codewars.api.utils").HEX24

--- Language fields the editor percent-encodes inside the embedded blob.
local ENCODED_FIELDS = { "answer", "setup", "fixture", "example_fixture", "package" }

--- Decode `%XX` escapes. The editor encodes with encodeURIComponent, which
--- never emits `+` for a space, so `+` is deliberately left alone.
---@param s string
---@return string
function kata_page.percent_decode(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

--- Read the JS string literal opening at `init` (the index of its `"`),
--- honouring backslash escapes, and return its raw still-escaped contents.
--- A plain `"(.-)"` pattern cannot do this: the blob is full of `\"`, and the
--- sequence `\")` occurs inside it, which would terminate the match early.
---@param html string
---@param init integer index of the opening quote
---@return string?
local function js_string(html, init)
    local buf, i = {}, init + 1
    while i <= #html do
        local c = html:sub(i, i)
        if c == "\\" then
            buf[#buf + 1] = html:sub(i, i + 1)
            i = i + 2
        elseif c == '"' then
            return table.concat(buf)
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    return nil
end

--- Decode the embedded `data: JSON.parse("…")` blob into a table.
--- The literal's contents are themselves a JSON string body, so decoding it as
--- one yields the JSON text — no hand-rolled unescaping needed.
---@param html string
---@return table?
function kata_page.parse_data_blob(html)
    if type(html) ~= "string" then
        return nil
    end
    local marker = html:find('data:%s*JSON%.parse%(%s*"')
    if not marker then
        return nil
    end
    local quote = html:find('"', marker, true)
    local raw = quote and js_string(html, quote)
    if not raw then
        return nil
    end
    local ok_text, json_text = pcall(vim.json.decode, '"' .. raw .. '"')
    if not ok_text or type(json_text) ~= "string" then
        return nil
    end
    local ok_data, data = pcall(vim.json.decode, json_text)
    if not ok_data or type(data) ~= "table" then
        return nil
    end
    return data
end

--- The opening tag of `kind` carrying `id="<id>"`, whatever order its
--- attributes appear in.
---@param html string
---@param kind string "input"|"select"|"textarea"
---@param id string
---@return string?
local function tag_by_id(html, kind, id)
    local needle = ('id="%s"'):format(id)
    for tag in html:gmatch("<" .. kind .. "[^>]*>") do
        if tag:find(needle, 1, true) then
            return tag
        end
    end
    return nil
end

--- `value="…"` of the input with this id, HTML-unescaped.
---@param html string
---@param id string
---@return string
function kata_page.input_value(html, id)
    local tag = tag_by_id(html, "input", id)
    local value = tag and tag:match('value="([^"]*)"')
    return value and page.unescape(value) or ""
end

--- Whether the checkbox with this id is checked.
---@param html string
---@param id string
---@return boolean
function kata_page.checkbox_checked(html, id)
    local tag = tag_by_id(html, "input", id)
    return tag ~= nil and tag:find("checked", 1, true) ~= nil
end

--- `value` of the `<option selected>` inside the select with this id.
--- Returns "" for the editor's blank "unset" option, matching RANKS[1].
---@param html string
---@param id string
---@return string
function kata_page.select_value(html, id)
    local open = html:find(('<select[^>]-id="%s"'):format(id))
    if not open then
        return ""
    end
    local body = html:sub(open):match("^.-</select>") or ""
    for option in body:gmatch("<option[^>]*>") do
        if option:find("selected", 1, true) then
            return option:match('value="([^"]*)"') or ""
        end
    end
    return ""
end

--- Contents of the textarea with this id, HTML-unescaped. HTML drops a single
--- newline directly after the open tag, and the real page relies on that — so
--- the description would otherwise load with a phantom blank first line.
---@param html string
---@param id string
---@return string
function kata_page.textarea_value(html, id)
    local open = html:find(('<textarea[^>]-id="%s"[^>]*>'):format(id))
    if not open then
        return ""
    end
    local body = html:sub(open):match("^<textarea[^>]*>(.-)</textarea>")
    if not body then
        return ""
    end
    return page.unescape((body:gsub("^\r?\n", "")))
end

--- The kata metadata carried by the editor's `code_challenge[...]` controls.
---@param html string
---@return table
function kata_page.parse_code_challenge(html)
    return {
        name = kata_page.input_value(html, "code_challenge_name"),
        category = kata_page.input_value(html, "code_challenge_category"),
        estimated_rank = kata_page.select_value(html, "code_challenge_estimated_rank"),
        tags_text = kata_page.input_value(html, "code_challenge_tags_text"),
        coauthors_wanted = kata_page.checkbox_checked(html, "code_challenge_coauthors_wanted"),
        description = kata_page.textarea_value(html, "code_challenge_description"),
    }
end

---@class cw.KataModel
---@field id string kata id (24-hex)
---@field language string the language this edit page was opened for
---@field published boolean
---@field languages table<string, table> per-language { id, name, answer, setup, fixture, example_fixture, package }
---@field code_challenge table { name, category, estimated_rank, tags_text, coauthors_wanted, description }
---@field test_frameworks table<string, string>
---@field version_info table<string, { id: string, label: string, default: boolean }[]> every runtime the editor offers, per language
---@field fixtures_locked boolean

--- Parse a kata edit page into the workspace model. Returns nil when the page
--- is not an editor at all — a deleted kata redirects to the marketing page,
--- which still contains an `App.setup` call but carries no kata data.
---@param html string
---@return cw.KataModel?
function kata_page.parse_edit_page(html)
    local data = kata_page.parse_data_blob(html)
    if type(data) ~= "table" or type(data.languages) ~= "table" or type(data.id) ~= "string" then
        return nil
    end

    local languages = {}
    for lang, lm in pairs(data.languages) do
        if type(lm) == "table" then
            local decoded = { id = lm.id or "", name = lm.name or lang }
            for _, field in ipairs(ENCODED_FIELDS) do
                decoded[field] = kata_page.percent_decode(lm[field] or "")
            end
            languages[lang] = decoded
        end
    end

    return {
        id = data.id,
        language = data.language or next(languages) or "",
        published = data.published == true,
        languages = languages,
        code_challenge = kata_page.parse_code_challenge(html),
        test_frameworks = type(data.testFrameworks) == "table" and data.testFrameworks or {},
        -- The editor ships every runtime it offers for all 58 languages, not
        -- just the ones this kata uses — that is what makes adding a language
        -- possible without a second request.
        version_info = type(data.versionInfo) == "table" and data.versionInfo or {},
        fixtures_locked = data.fixturesLocked == true,
    }
end

--- Extract a kata id from a raw id or any kata URL form
--- (`/kata/{id}`, `/kata/{id}/edit`, `/kata/{id}/edit/{lang}`).
---@param input string?
---@return string? id
function kata_page.parse_ref(input)
    if type(input) ~= "string" then
        return nil
    end
    local trimmed = vim.trim(input)
    if trimmed:match("^" .. HEX24 .. "$") then
        return trimmed
    end
    return trimmed:match("/kata/(" .. HEX24 .. ")")
end

--- Fetch and parse a kata's edit page (cookie auth — it is the author's own
--- draft). Read-only: nothing is mutated by loading.
--- With no language, `/edit` redirects to the kata's own default and the
--- parsed model reports which one that was, so callers need not guess.
---@param id string kata id (24-hex)
---@param lang string? language slug; nil = let Codewars pick the default
---@param cb fun(model: cw.KataModel?, err: cw.err?)
function kata_page.fetch_edit(id, lang, cb)
    local url = (lang and lang ~= "")
        and ("https://www.codewars.com/kata/%s/edit/%s"):format(id, lang)
        or ("https://www.codewars.com/kata/%s/edit"):format(id)
    page.fetch(url, function(body, perr)
        if perr then
            return cb(nil, page.fetch_err("the kata editor", perr))
        end
        local model = kata_page.parse_edit_page(body)
        if not model then
            -- Codewars serves the marketing page for any kata id it will not
            -- show you, so the body cannot say WHY. Name the causes in the
            -- order they actually happen — by far the most common is passing a
            -- kumite id, since a kata only exists once convert has created it.
            return cb(nil, {
                msg = ("Could not open the kata editor for %s. If that is a kumite id, open it with "
                    .. ":CW kumite open and run :CW kumite convert — that creates the kata. "
                    .. "Otherwise check you are signed in and that the kata is yours."):format(id),
            })
        end
        cb(model, nil)
    end)
end

return kata_page
