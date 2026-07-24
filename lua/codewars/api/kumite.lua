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

local HEX24 = "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x"

-- Verified from /kumite/new's defaultFrameworks payload (2026-07-24). Used
-- when starting a fresh kumite so it runs with the right test framework;
-- unknown languages fall back to cw-2.
local DEFAULT_FRAMEWORK = {
    ruby = "cw-2", javascript = "cw-2", coffeescript = "cw-2", python = "cw-2",
    php = "phpunit", java = "junit", haskell = "hspec", clojure = "clojure.test",
    csharp = "nunit", elixir = "exunit", elm = "test", erlang = "eunit",
    typescript = "mocha", dart = "test", c = "criterion", cpp = "igloo",
    nasm = "criterion", rust = "rust", julia = "factcheck", crystal = "spec",
    fsharp = "fuchu", ocaml = "ounit", go = "gotest", lua = "busted", nim = "unittest",
    r = "testthat", kotlin = "junit5", scala = "scalatest", groovy = "spock",
    swift = "xctest", sql = "sql", shell = "cw-2", powershell = "pester", solidity = "truffle",
}

---@param lang string
---@return string test framework id
function kumite.default_framework(lang)
    return DEFAULT_FRAMEWORK[lang] or "cw-2"
end

-- Verified from /kumite/new's versionInfo payload (2026-07-24): the runtime
-- each language's form preselects (its `default:true` entry). Kumite runs must
-- send this — Codewars' runner otherwise falls back to a legacy runtime (e.g.
-- Python 2.7, where `import codewars_test` fails). Snippet JSON carries no
-- version, so new kumites AND forks rely on this. nil = let the runner decide.
local DEFAULT_VERSION = {
    agda = "2.6.2", bf = "2004", c = "c18_clang-8", cfml = "lucee5.2",
    clojure = "1.8.x", cobol = "3.1-ibm", coffeescript = "1.x", commonlisp = "2.0",
    coq = "8.15", cpp = "c++17_clang-8", crystal = "1.0", csharp = "10.0",
    d = "2.098", dart = "3.3", elixir = "1.15", elm = "0.19", erlang = "26",
    factor = "0.99", forth = "0.7", fortran = "f2008", fsharp = "6.0", go = "1.20",
    groovy = "2.5", haskell = "9.2.5", haxe = "4.0", idris = "1.3", java = "21",
    javascript = "22.x", julia = "1.5", kotlin = "1.3", lambdacalc = "1.0",
    lean = "3.39.1", lua = "5.3", nasm = "2.11", nim = "1.6", objc = "gnustep",
    ocaml = "5.0.0", pascal = "3.2", perl = "5.30", php = "7.x", powershell = "7.2",
    prolog = "8.0", purescript = "0.15", python = "3.11", r = "3.x", racket = "8.1",
    raku = "2020.09", reason = "3.3", riscv = "rv64", ruby = "3.0", rust = "1.66",
    scala = "3.0", shell = "bash", solidity = "0.8.16", sql = "postgres@13.0",
    swift = "5.9", typescript = "4.9", vb = "15.5",
}

--- The default runtime version to submit for a kumite run in this language.
---@param lang string
---@return string? languageVersion, or nil to let the runner default
function kumite.default_version(lang)
    return DEFAULT_VERSION[lang]
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
            cb({
                id = res.id,
                title = res.title or "(untitled)",
                description = res.description or "",
                language = res.language or "",
                code = res.code or "",
                fixture = res.fixture or "",
                ["package"] = res["package"] or "",
                test_framework = res.testFramework or "cw-2",
                test_language = res.testLanguage,
                state = res.state or "published",
                parent_id = res.parentId,
                published_at = res.publishedAt,
                author = res.user and res.user.username or nil,
            })
        end,
    })
end

return kumite
