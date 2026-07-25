local utils = require("codewars.api.utils")
local urls = require("codewars.api.urls")
local kumite = require("codewars.api.kumite")
local page = require("codewars.api.page")

---@class cw.Api.Kata
local kata = {}

---@param slug string
---@param cb? function
---@return table?, cw.err?
function kata.get(slug, cb)
    local endpoint = urls.kata:format(slug)

    if cb then
        utils.get(endpoint, { callback = cb })
    else
        return utils.get(endpoint)
    end
end

--- Kata authoring mutations (contracts live-captured 2026-07-25 from the kata
--- editor at /kata/{id}/edit). A kata reaches this plugin via `:CW kumite
--- convert`, which creates a draft; from there the editor Saves, Validates,
--- Publishes, Un-publishes and Deletes it. Routes are the editor's own
--- `routes` map:
---   save      POST   /kata/{id}
---   publish   POST   /kata/{id}/publish       -> { success, dmid }  (async)
---   unpublish POST   /kata/{id}/unpublish
---   destroy   DELETE /kata/{id}
--- Save/Delete return a Turbolinks HTML re-render, not JSON — success is the
--- absence of a rendered validation error (see `kata.render_error`). Publish is
--- two-step: it returns a deferred-job id to poll at /api/v1/deferred/{dmid}.

local HEX24 = "^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"

-- Async publish: poll the deferred job until it stops reporting progress.
local POLL_INTERVAL_MS = 1200
local MAX_POLLS = 25 -- ~30s ceiling before we tell the user to check the site

--- Discipline picker: display label <-> `code_challenge[category]` slug, in the
--- editor's on-screen order. Verified from the editor's `#categories` list.
kata.CATEGORIES = {
    { value = "reference", label = "Fundamentals" },
    { value = "algorithms", label = "Algorithms" },
    { value = "bug_fixes", label = "Bug Fixes" },
    { value = "refactoring", label = "Refactoring" },
    { value = "games", label = "Puzzles" },
}

--- Estimated-rank picker: `code_challenge[estimated_rank]` value <-> label.
--- Verified from the editor's `#code_challenge_estimated_rank` options ("" =
--- leave unset; kyu ranks are negative, 8 kyu = "-8" … 1 kyu = "-1").
kata.RANKS = {
    { value = "", label = "— (unset)" },
    { value = "-8", label = "8 kyu" },
    { value = "-7", label = "7 kyu" },
    { value = "-6", label = "6 kyu" },
    { value = "-5", label = "5 kyu" },
    { value = "-4", label = "4 kyu" },
    { value = "-3", label = "3 kyu" },
    { value = "-2", label = "2 kyu" },
    { value = "-1", label = "1 kyu" },
}

--- True for a Codewars kata id (24 hex chars).
---@param id any
---@return boolean
function kata.is_server_id(id)
    return type(id) == "string" and id:match(HEX24) ~= nil
end

--- Default runtime version for a language (shared with kumite; the editor's
--- versionInfo marks the same `default:true` entries).
---@param lang string
---@return string?
function kata.default_version(lang)
    return kumite.default_version(lang)
end

--- Build one `languages[lang]` entry for a save/publish body. `id` is the
--- per-language snippet id from the loaded model (empty for a language being
--- added). `default_version` falls back to the language default.
---@param lang string
---@param m table { id?, answer?, setup?, fixture?, example_fixture?, package?, default_version? }
---@return table
function kata.language_payload(lang, m)
    return {
        id = m.id or "",
        name = lang,
        answer = m.answer or "",
        setup = m.setup or "",
        fixture = m.fixture or "",
        example_fixture = m.example_fixture or "",
        ["package"] = m["package"] or "",
        default_version = m.default_version or kata.default_version(lang) or "",
    }
end

--- Build the full `{ languages, language, code_challenge }` mutation body shared
--- by save and publish (verified /kata contract, 2026-07-25). Booleans are
--- coerced so an update never sends nil for `coauthors_wanted`.
---@param m table { language, languages = { [lang] = {...} }, code_challenge = {...} }
---@return table
function kata.save_payload(m)
    local languages = {}
    for lang, lm in pairs(m.languages or {}) do
        languages[lang] = kata.language_payload(lang, lm)
    end
    local cc = m.code_challenge or {}
    return {
        languages = languages,
        language = m.language or "",
        code_challenge = {
            name = cc.name or "",
            category = cc.category or "",
            estimated_rank = cc.estimated_rank or "",
            tags_text = cc.tags_text or "",
            coauthors_wanted = cc.coauthors_wanted == true,
            description = cc.description or "",
        },
    }
end

--- Detect a rendered validation error in a Turbolinks/editor HTML response
--- (from save, an immediate publish rejection, or a finished deferred job).
--- The editor re-renders the form with an `<li data-field="X">message</li>`
--- inside its error alert-box, and embeds a `languageErrors` object; a clean
--- save has neither. Returns a human message, or nil when there is no error.
---@param body any string HTML, or a decoded table
---@return string?
function kata.render_error(body)
    if type(body) ~= "string" then
        return nil
    end
    local field, msg = body:match('<li data%-field="([^"]-)">%s*(.-)%s*</li>')
    if field and msg then
        return ("%s: %s"):format(field, page.unescape((msg:gsub("%s+", " "))))
    end
    if body:find("languageErrors", 1, true) then
        -- message is JSON-escaped inside the embedded blob (\"message\":\"…\")
        local m = body:match('\\"message\\":\\"(.-)\\"') or body:match('"message":"(.-)"')
        return m and page.unescape(m) or "Codewars rejected the kata (validation error)."
    end
    return nil
end

--- Save a kata draft in place: `POST /kata/{id}` with the full model. The
--- response is a Turbolinks re-render (not JSON); success is the absence of a
--- rendered validation error.
---@param id string kata id (24-hex)
---@param model table save_payload input
---@param cb fun(err: cw.err?)
function kata.save(id, model, cb)
    utils.post(("/kata/%s"):format(id), {
        body = kata.save_payload(model),
        callback = function(res, err)
            if err then
                return cb(err)
            end
            local why = kata.render_error(res)
            if why then
                return cb({ msg = why })
            end
            cb(nil)
        end,
    })
end

--- Delete a kata draft: `DELETE /kata/{id}`. The response is a Turbolinks
--- redirect to /kata/new; a non-error HTTP status is success. Destructive and
--- irreversible — callers confirm first.
---@param id string
---@param cb fun(err: cw.err?)
function kata.delete(id, cb)
    utils.delete(("/kata/%s"):format(id), {
        callback = function(_, err)
            cb(err)
        end,
    })
end

--- Un-publish (hide) a published kata: `POST /kata/{id}/unpublish` (route
--- verified; response treated leniently — any non-error reply is success).
---@param id string
---@param cb fun(err: cw.err?)
function kata.unpublish(id, cb)
    utils.post(("/kata/%s/unpublish"):format(id), {
        body = vim.empty_dict(),
        callback = function(res, err)
            if err then
                return cb(err)
            end
            if type(res) == "table" and res.success == false then
                return cb({ msg = "Codewars rejected the unpublish." })
            end
            local why = kata.render_error(res)
            if why then
                return cb({ msg = why })
            end
            cb(nil)
        end,
    })
end

--- Poll a publish's deferred job until it finishes (design: async publish).
--- While running, `/api/v1/deferred/{dmid}` returns `{_type:"progress", …}`;
--- the terminal reply is `{html:"…"}` (the re-rendered editor), which carries a
--- validation error on failure. Bounded by MAX_POLLS.
---@param dmid string
---@param id string kata id (for the success URL)
---@param cb fun(url: string?, err: cw.err?)
---@param tries integer?
function kata.poll_publish(dmid, id, cb, tries)
    tries = tries or 0
    if tries >= MAX_POLLS then
        return cb(nil, { msg = "Publish is taking too long — check it on codewars.com." })
    end
    utils.get(("/api/v1/deferred/%s"):format(dmid), {
        callback = function(res, err)
            if err then
                return cb(nil, err)
            end
            if type(res) == "table" and res._type == "progress" then
                return vim.defer_fn(function()
                    kata.poll_publish(dmid, id, cb, tries + 1)
                end, POLL_INTERVAL_MS)
            end
            local html = (type(res) == "table" and res.html) or (type(res) == "string" and res) or ""
            local why = kata.render_error(html)
            if why then
                return cb(nil, { msg = why })
            end
            cb(("https://www.codewars.com/kata/%s"):format(id), nil)
        end,
    })
end

--- Load a kata's authoring model by scraping its edit page (design KP1b).
--- Read-only. Delegates to `api.kata_page`, which owns the page contract;
--- kept here so callers have one kata API surface.
---@param id string kata id (24-hex)
---@param lang string language slug
---@param cb fun(model: cw.KataModel?, err: cw.err?)
function kata.load(id, lang, cb)
    require("codewars.api.kata_page").fetch_edit(id, lang, cb)
end

--- Extract a kata id from a raw id or any `/kata/…` URL (design KP1b).
---@param input string?
---@return string? id
function kata.parse_ref(input)
    return require("codewars.api.kata_page").parse_ref(input)
end

--- Publish a kata: `POST /kata/{id}/publish` with the full model returns
--- `{success, dmid}` for an async job we then poll. The server runs the fixture
--- against the solution itself, so a bad solution/fixture surfaces as a deferred
--- validation error. Outward-facing — callers confirm first.
---@param id string
---@param model table save_payload input
---@param cb fun(url: string?, err: cw.err?) url is the public kata URL on success
function kata.publish(id, model, cb)
    utils.post(("/kata/%s/publish"):format(id), {
        body = kata.save_payload(model),
        callback = function(res, err)
            if err then
                return cb(nil, err)
            end
            if type(res) == "table" and res.success == true and type(res.dmid) == "string" then
                return kata.poll_publish(res.dmid, id, cb)
            end
            -- No dmid: either a rendered validation error or an unexpected shape.
            local why = kata.render_error(res)
            return cb(nil, { msg = why or "Codewars rejected the kata publish." })
        end,
    })
end

return kata
