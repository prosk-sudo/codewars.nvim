local urls = require("codewars.api.urls")
local page = require("codewars.api.page")

---@class cw.Api.Kumite
local kumite = {}

---@class cw.KumiteListEntry
---@field id string 24-hex snippet id (from the item's Fork link)
---@field parent_id string? set when the entry is a fork
---@field title string
---@field author string? forker (first author on the item)
---@field forked_from_author string? original author on "A vs. B" items
---@field language string?
---@field published_at string? ISO 8601
---@field code string? full snippet code from the list page

---@class cw.KumiteSnippet
---@field id string
---@field title string
---@field description string
---@field language string
---@field code string
---@field fixture string
---@field package string
---@field test_framework string
---@field test_language string? language the fixture is written in (may differ from `language`)
---@field state string "published"|"draft"
---@field parent_id string?
---@field published_at string?
---@field author string?

local HEX24 = require("codewars.api.utils").HEX24

--- Test framework / runtime defaults now live in codewars.languages.runtimes
--- (they describe Codewars languages, not kumite). Re-exported so existing
--- callers keep working.
---@param lang string
---@return string test framework id
function kumite.default_framework(lang)
    return require("codewars.languages.runtimes").default_framework(lang)
end

---@param lang string
---@return string? languageVersion, or nil to let the runner default
function kumite.default_version(lang)
    return require("codewars.languages.runtimes").default_version(lang)
end

--- Extract a snippet id from a raw id or any kumite URL form
--- (`/kumite/{id}`, `/kumite/{parent}?sel={id}`). Prefers `sel=`.
---@param input string?
---@return string? id
function kumite.parse_ref(input)
    if type(input) ~= "string" then
        return nil
    end
    local trimmed = vim.trim(input)
    if trimmed:match("^" .. HEX24 .. "$") then
        return trimmed
    end
    local sel = trimmed:match("[?&]sel=(" .. HEX24 .. ")")
    if sel then
        return sel
    end
    return trimmed:match("/kumite/(" .. HEX24 .. ")")
end

--- Parse a kumite browse page (design §2.1; verified live 2026-07-24).
--- Items are `div.code-snippet-list-item` blocks; each carries exactly one
--- Fork link `/kumite/new?parent={id}` naming the snippet id.
---@param html string
---@return { entries: cw.KumiteListEntry[], current_page: integer, last_page: integer }
function kumite.parse_list_html(html)
    local entries = {}

    -- Segment on item roots; the class list has trailing utility classes.
    local starts = {}
    local pos = 1
    while true do
        local s = html:find('class="code%-snippet%-list%-item ', pos)
        if not s then break end
        starts[#starts + 1] = s
        pos = s + 1
    end

    for i, s in ipairs(starts) do
        local seg = html:sub(s, (starts[i + 1] or #html + 1) - 1)

        local id = seg:match("/kumite/new%?parent=(" .. HEX24 .. ")")
        local title_href, title = seg:match('<h3 class="m%-0"><a class="is%-alt" href="/kumite/([^"]+)">(.-)</a>')
        if id and title then
            local parent_id = title_href:match("^(" .. HEX24 .. ")%?sel=")
            if parent_id == id then
                parent_id = nil
            end

            local author = seg:match('icon%-moon%-user "></i><a href="/users/[^"]+">([^<]+)</a>')
            local forked_from = seg:match('vs%.</span><a href="/users/[^"]+">([^<]+)</a>')
            local code = seg:match('<pre lang="[^"]*"><code>(.-)</code>')

            entries[#entries + 1] = {
                id = id,
                parent_id = parent_id,
                title = page.unescape(title),
                author = author and page.unescape(author) or nil,
                forked_from_author = forked_from and page.unescape(forked_from) or nil,
                language = seg:match('<pre lang="([^"]*)"'),
                published_at = seg:match('<time%-ago[^>]*datetime="([^"]+)"'),
                code = code and page.unescape(code) or nil,
            }
        end
    end

    local current_page, last_page = 1, 1
    local pagination = html:match('class="pagination"(.-)</nav>')
    if pagination then
        current_page = tonumber(pagination:match('<span class="page current">(%d+)')) or 1
        last_page = current_page
        for n in pagination:gmatch("page=(%d+)") do
            local num = tonumber(n)
            if num and num > last_page then
                last_page = num
            end
        end
    end

    return { entries = entries, current_page = current_page, last_page = last_page }
end

--- Fetch one browse page. Public — no auth required.
--- Distinguishes drift (page lost its kumite markup entirely) from a
--- legitimately empty page (design §3.6).
---@param lang string? language slug; nil = all languages
---@param page_num integer? defaults to 1
---@param cb fun(result: { entries: cw.KumiteListEntry[], current_page: integer, last_page: integer }?, err: cw.err?)
function kumite.fetch_list(lang, page_num, cb)
    local query = {}
    if lang and lang ~= "" then
        query[#query + 1] = "language=" .. lang
    end
    if page_num and page_num > 1 then
        query[#query + 1] = "page=" .. page_num
    end
    local url = urls.base .. "/kumite"
    if #query > 0 then
        url = url .. "?" .. table.concat(query, "&")
    end

    page.fetch(url, function(body, perr)
        if perr then
            return cb(nil, page.fetch_err("the kumite list", perr))
        end

        local result = kumite.parse_list_html(body)
        if #result.entries == 0 and not body:find("code-snippet", 1, true) then
            return cb(nil, { msg = "Could not parse the kumite page. Codewars may have changed their HTML format." })
        end
        cb(result)
    end)
end

--- Public-view snippet built from browse-list data — the signed-out
--- fallback shape (design §3.6). Owns the cw.KumiteSnippet field list the
--- same way fetch_snippet owns the full-JSON mapping.
---@param entry cw.KumiteListEntry
---@return cw.KumiteSnippet
function kumite.snippet_from_list_entry(entry)
    return {
        id = entry.id,
        title = entry.title,
        description = "",
        language = entry.language or "",
        code = entry.code or "",
        fixture = "",
        ["package"] = "",
        test_framework = "cw-2",
        state = "published",
        parent_id = entry.parent_id,
        published_at = entry.published_at,
        author = entry.author,
        forked_from_author = entry.forked_from_author,
    }
end

--- Fetch one snippet's full JSON (cookie auth; design §2.2).
---@param id string
---@param cb fun(snippet: cw.KumiteSnippet?, err: cw.err?)
function kumite.fetch_snippet(id, cb)
    local api_utils = require("codewars.api.utils")
    api_utils.get("/api/v1/code-snippets/" .. id, {
        callback = function(res, err)
            if err then
                return cb(nil, err)
            end
            if type(res) ~= "table" or not res.id then
                return cb(nil, { msg = "Unexpected code-snippets response. Codewars may have changed their API." })
            end
            -- The code-snippets API serves author text HTML-ESCAPED: a
            -- snippet typed as `return "woof"` on the website comes back as
            -- `return &quot;woof&quot;` (verified live 2026-07-25 on `code`
            -- and `fixture`). The website unescapes for display, so an
            -- editable buffer must too — otherwise the entities look like
            -- real source, and saving writes them back as literal text.
            -- parse_list_html already does this for the browse path; this is
            -- the same treatment for the single-snippet path.
            cb({
                id = res.id,
                title = page.unescape(res.title or "(untitled)"),
                description = page.unescape(res.description or ""),
                language = res.language or "",
                code = page.unescape(res.code or ""),
                fixture = page.unescape(res.fixture or ""),
                ["package"] = page.unescape(res["package"] or ""),
                test_framework = res.testFramework or "cw-2",
                test_language = res.testLanguage,
                state = res.state or "published",
                parent_id = res.parentId,
                published_at = res.publishedAt,
                author = res.user and res.user.username or nil,
                -- draft_payload re-sends this on every save; leaving it out
                -- here meant saving a fetched PRIVATE kumite sent secret=false
                -- and flipped it public.
                secret = res.secret == true,
            })
        end,
    })
end

--- True for a Codewars snippet id (24 hex chars); false for a local id
--- ("local-…"), which means the draft has never been saved to the server.
---@param id any
---@return boolean
function kumite.is_server_id(id)
    return type(id) == "string" and #id == 24 and id:match("^%x+$") ~= nil
end

--- Build the `code_snippet` mutation body for a draft save (verified /kumite
--- contract, 2026-07-24). `example_fixture` mirrors `fixture` until sample
--- tests are modelled separately (TODO); `secret` is re-sent so an update
--- never flips visibility.
---@param m table snippet-like { language, language_version, test_framework, title, description, code, fixture, example_fixture?, package, parent_id, code_challenge_id?, secret? }
---@return table
function kumite.draft_payload(m)
    local fixture = m.fixture or ""
    return {
        code_snippet = {
            language = m.language or "",
            language_version = m.language_version or "",
            test_framework = m.test_framework or "cw-2",
            title = m.title or "",
            description = m.description or "",
            user_tags = "",
            parent_id = m.parent_id or "",
            code_challenge_id = m.code_challenge_id or "",
            secret = m.secret == true,
            code = m.code or "",
            ["package"] = m["package"] or "",
            fixture = fixture,
            example_fixture = m.example_fixture or fixture,
        },
    }
end

--- First validation error the server attached to any field, if any.
---@param res table? decoded /kumite response
---@return string?
local function first_field_error(res)
    local fields = res and res.fields and res.fields.code_snippet
    if type(fields) ~= "table" then
        return nil
    end
    for key, f in pairs(fields) do
        if type(f) == "table" and type(f.errors) == "table" and f.errors[1] then
            return ("%s: %s"):format(key, tostring(f.errors[1]))
        end
    end
    return nil
end

--- Save a kumite draft (design §2.4, P3). Create (`POST /kumite`) when `id` is
--- nil or a local id; update (`PUT /kumite/{id}`) for an existing server draft.
--- Both send JSON `{ code_snippet = {...} }` and return
--- `{ success, id?, url?, fields }`. No server side effects beyond the draft.
---@param id string? server id (24-hex) or nil/local id (→ create)
---@param model table snippet-like fields for draft_payload
---@param cb fun(result: { id: string }?, err: cw.err?)
function kumite.save_draft(id, model, cb)
    local api_utils = require("codewars.api.utils")
    local update = kumite.is_server_id(id)
    local endpoint = update and ("/kumite/" .. id) or "/kumite"
    local method = update and api_utils.put or api_utils.post
    method(endpoint, {
        body = kumite.draft_payload(model),
        callback = function(res, err)
            if err then
                return cb(nil, err)
            end
            if type(res) ~= "table" or res.success ~= true then
                return cb(nil, { msg = first_field_error(res) or "Codewars rejected the kumite save." })
            end
            cb({ id = res.id or id }, nil)
        end,
    })
end

--- Unpublish (hide) a published kumite (contract live-captured 2026-07-25):
--- `POST /kumite/{id}/unpublish` (empty body) → `{ success = true, data = … }`.
--- Reversible — publishing again re-lists it.
---@param id string
---@param cb fun(err: cw.err?)
function kumite.unpublish(id, cb)
    require("codewars.api.utils").post(("/kumite/%s/unpublish"):format(id), {
        body = vim.empty_dict(),
        callback = function(res, err)
            if err then
                return cb(err)
            end
            if type(res) ~= "table" or res.success ~= true then
                return cb({ msg = "Codewars rejected the unpublish." })
            end
            cb(nil)
        end,
    })
end

--- Convert a kumite into a new kata (contract live-captured 2026-07-25):
--- `POST /kumite/{id}/convert` (empty body) creates a new kata FROM the kumite
--- and unpublishes/hides the kumite. Returns the kata's edit URL
--- (`res.data.url` = `/kata/{new_id}/edit`).
---@param id string
---@param cb fun(kata_edit_url: string?, err: cw.err?)
function kumite.convert_to_kata(id, cb)
    require("codewars.api.utils").post(("/kumite/%s/convert"):format(id), {
        body = vim.empty_dict(),
        callback = function(res, err)
            if err then
                return cb(nil, err)
            end
            local url = type(res) == "table" and res.success == true
                and type(res.data) == "table" and res.data.url
            if type(url) ~= "string" then
                -- Prefer whatever the server said over a generic shrug. The
                -- usual cause is converting a kumite that already has a kata,
                -- which the workspace pre-checks via snippet.state.
                -- Surface what the server actually said. The caller adds its
                -- own "Convert failed — " prefix, so this must NOT repeat it,
                -- and a bare code like 422 is useless on its own: include every
                -- field the payload carried so the cause is diagnosable.
                local detail
                if type(res) == "table" then
                    local parts = {}
                    for _, key in ipairs({ "reason", "error", "message", "status" }) do
                        if res[key] ~= nil then
                            parts[#parts + 1] = ("%s=%s"):format(key, tostring(res[key]))
                        end
                    end
                    if type(res.data) == "table" then
                        for k, v in pairs(res.data) do
                            if type(v) ~= "table" then
                                parts[#parts + 1] = ("data.%s=%s"):format(k, tostring(v))
                            end
                        end
                    end
                    detail = #parts > 0 and table.concat(parts, " ") or nil
                elseif type(res) == "string" and res ~= "" then
                    detail = res:sub(1, 200)
                end
                return cb(nil, {
                    msg = (detail or "Codewars rejected it and said nothing useful.")
                        .. " — if this kumite was already converted its kata exists already;"
                        .. " otherwise check it is saved, is yours, and has a fixture.",
                })
            end
            cb(url, nil)
        end,
    })
end

return kumite
