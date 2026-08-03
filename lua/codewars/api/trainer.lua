local log = require("codewars.logger")
local api_utils = require("codewars.api.utils")

---@class cw.Api.Trainer
local trainer = {}

--- Server strategy tokens for GET /trainer/peek/{language}/{strategy}.
--- LIVE-CAPTURED 2026-08-03 from authenticated browser devtools: all four
--- return HTTP 200 JSON { success, strategy, language, id, name, rank, href }.
--- `dequeue=false` is an idempotent peek — the server keeps the current
--- challenge per (strategy, language), so re-running returns the SAME kata.
--- `dequeue=true` pops the queue (the skip mechanism). A changed token or
--- response shape surfaces through the drift error in _parse — never silently.
trainer.STRATEGIES = {
    fundamentals = "reference_workout",
    rank_up = "default",
    practice_and_repeat = "retrain_workout",
    beta = "beta_workout",
    -- "random" is intentionally absent: Focus→Random resolves client-side
    -- via problemlist_utils.random_for_lang (eng review decision #7).
    -- (A server-side "random" token also exists if that ever changes.)
}

-- Slug/id charset accepted from the trainer (also what the HTML branch
-- extracts). The value flows into file paths and the :CW open shell
-- fallback, so anything outside it is treated as drift.
local SLUG_PAT = "[%w%-_]+"

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
        local slug = type(res.slug) == "string" and res.slug:match("^" .. SLUG_PAT .. "$") or nil
        local id = type(res.id) == "string" and res.id:match("^" .. SLUG_PAT .. "$") or nil
        if slug then
            return { slug = slug, id = id }
        end
        -- The peek endpoint returns only an id; Kata:new accepts slug or hex id
        if id then
            return { slug = id, id = id }
        end
    elseif type(res) == "string" then
        -- HTML shape: look for a /kata/{id-or-slug}/train link
        local slug = res:match("/kata/(" .. SLUG_PAT .. ")/train")
        if slug then
            return { slug = slug }
        end
        -- An expired session can 200 with the login page instead of a 401;
        -- that's an auth failure, not endpoint drift. (solutions.fetch has
        -- its own login-redirect check tuned to solution-page markup.)
        if res:lower():find("sign in", 1, true) then
            return nil, { auth = true, msg = "Session expired or invalid. Run :CW cookie to re-authenticate." }
        end
    end

    return nil, {
        msg = "Codewars trainer response has an unexpected shape. "
            .. "The endpoint may have changed — please open an issue on codewars.nvim.",
    }
end

-- One fetch at a time: skip advances the server-side focus queue, so a
-- second in-flight request would double-pop and race the mounts.
local pending = false

---@param strategy string
---@param language string
---@param dequeue boolean
---@return string endpoint
local function peek_endpoint(strategy, language, dequeue)
    return ("/trainer/peek/%s/%s?dequeue=%s"):format(language, strategy, dequeue and "true" or "false")
end

--- Shared response handling: 404 language mapping, parse, drift error.
---@param category string
---@param language string
---@param cb fun(kata: { slug: string, id: string? }?, err: cw.err?)
local function handle_response(category, language, cb, res, err)
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
end

--- Peek the current kata for a focus category + language.
--- Idempotent: the server owns the focus pointer, so re-running returns the
--- same kata until it is solved or skipped (trainer.skip).
---@param category string plugin-internal key (see picker.focus_categories)
---@param language string
---@param cb fun(kata: { slug: string, id: string? }?, err: cw.err?)
function trainer.next_kata(category, language, cb)
    local strategy = trainer.STRATEGIES[category]
    if not strategy then
        return cb(nil, { msg = ("Unknown focus category: %s"):format(tostring(category)) })
    end

    if pending then
        return cb(nil, { msg = "Already fetching a focus kata..." })
    end
    pending = true

    -- Idempotent peek: the shared 5xx retry default is safe here.
    api_utils.get(peek_endpoint(strategy, language, false), {
        callback = function(res, err)
            pending = false
            handle_response(category, language, cb, res, err)
        end,
    })
end

--- Skip the current kata: pop the queue (dequeue=true), then peek the new
--- head and return it. The follow-up peek makes the result deterministic
--- regardless of whether the pop returns the old or the new head.
---@param category string plugin-internal key (see picker.focus_categories)
---@param language string
---@param cb fun(kata: { slug: string, id: string? }?, err: cw.err?)
function trainer.skip(category, language, cb)
    local strategy = trainer.STRATEGIES[category]
    if not strategy then
        return cb(nil, { msg = ("Unknown focus category: %s"):format(tostring(category)) })
    end

    if pending then
        return cb(nil, { msg = "Already fetching a focus kata..." })
    end
    pending = true

    api_utils.get(peek_endpoint(strategy, language, true), {
        -- Non-idempotent: the pop advances the queue, so no retries.
        retry = 0,
        callback = function(res, err)
            if err then
                pending = false
                return handle_response(category, language, cb, res, err)
            end

            -- Confirm the pop parsed (drift check) before trusting the queue
            -- state, then fetch the new head.
            local _, perr = trainer._parse(res)
            if perr then
                pending = false
                log.debug(res)
                return cb(nil, perr)
            end

            api_utils.get(peek_endpoint(strategy, language, false), {
                callback = function(res2, err2)
                    pending = false
                    handle_response(category, language, cb, res2, err2)
                end,
            })
        end,
    })
end

return trainer
