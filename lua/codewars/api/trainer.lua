local log = require("codewars.logger")
local api_utils = require("codewars.api.utils")

---@class cw.Api.Trainer
local trainer = {}

--- Server strategy tokens for POST /api/v1/code-challenges/{lang}/train.
--- LIVE-VERIFIED 2026-07-02 against an authenticated session: all four
--- tokens return HTTP 200 with { success, name, slug, href, rank, ... }.
--- Token source: the dashboard focus chooser markup (strategy="..."
--- attributes). A changed token or response shape surfaces through the
--- drift error in _parse — never silently.
trainer.STRATEGIES = {
    fundamentals = "reference_workout",
    rank_up = "default",
    practice_and_repeat = "retrain_workout",
    beta = "beta_workout",
    -- "random" is intentionally absent: Focus→Random resolves client-side
    -- via problemlist_utils.random_for_lang (eng review decision #7).
    -- (A server-side "random" token also exists if that ever changes.)
}

--- Normalize a train response to { slug, id? }.
--- Accepts both response shapes from Open Q3: decoded JSON and raw HTML.
---@param res any decoded JSON table or raw body string
---@return { slug: string, id: string? }?, cw.err?
function trainer._parse(res)
    if type(res) == "table" then
        -- The server can 200 with success=false; mounting its slug anyway
        -- would silently train the wrong kata.
        if res.success == false then
            return nil, {
                msg = "Codewars trainer refused the request. Try again, or run :CW cookie if your session expired.",
            }
        end
        -- Legacy API shape: { success = true, slug = ..., id = ..., name = ... }
        -- Only accept slug-shaped values (same charset the HTML branch
        -- extracts): the slug flows into file paths and the :CW open shell
        -- fallback, so anything else is treated as drift.
        local slug = type(res.slug) == "string" and res.slug:match("^[%w%-_]+$") or nil
        local id = type(res.id) == "string" and res.id:match("^[%w%-_]+$") or nil
        if slug then
            return { slug = slug, id = id }
        end
        -- Some endpoints return only an id; Kata:new accepts slug or hex id
        if id then
            return { slug = id, id = id }
        end
    elseif type(res) == "string" then
        -- HTML shape: look for a /kata/{id-or-slug}/train link
        local slug = res:match("/kata/([%w%-_]+)/train")
        if slug then
            return { slug = slug }
        end
        -- An expired session can 200 with the login page instead of a 401;
        -- that's an auth failure, not endpoint drift (same detection as
        -- solutions.fetch's login-redirect check).
        if res:lower():find("sign in", 1, true) then
            return nil, { auth = true, msg = "Session expired or invalid. Run :CW cookie to re-authenticate." }
        end
    end

    return nil, {
        msg = "Codewars trainer response has an unexpected shape. "
            .. "The endpoint may have changed — please open an issue on codewars.nvim.",
    }
end

--- Fetch the next kata for a focus category + language.
---@param category string plugin-internal key (see picker.focus_categories)
---@param language string
---@param cb fun(kata: { slug: string, id: string? }?, err: cw.err?)
function trainer.next_kata(category, language, cb)
    local strategy = trainer.STRATEGIES[category]
    if not strategy then
        return cb(nil, { msg = ("Unknown focus category: %s"):format(tostring(category)) })
    end

    local endpoint = ("/api/v1/code-challenges/%s/train"):format(language)
    api_utils.post(endpoint, {
        body = { strategy = strategy },
        -- Non-idempotent: every POST advances the server-side focus queue,
        -- so the shared 5xx retry default would silently skip kata.
        retry = 0,
        callback = function(res, err)
            if err then
                if not err.auth and err.status == 404 then
                    err = {
                        status = 404,
                        msg = ("No %s kata available for %s — the trainer may not support this language."):format(
                            category, language
                        ),
                    }
                end
                return cb(nil, err)
            end

            local kata, perr = trainer._parse(res)
            if perr then
                log.debug(res)
                return cb(nil, perr)
            end
            cb(kata)
        end,
    })
end

return trainer
