local log = require("codewars.logger")
local api_utils = require("codewars.api.utils")

---@class cw.Api.Trainer
local trainer = {}

--- Server strategy tokens for GET /trainer/peek/{language}/{strategy}.
--- LIVE-CAPTURED 2026-08-03 from authenticated browser devtools: all four
--- return HTTP 200 JSON { success, strategy, language, id, name, rank, href }.
--- `dequeue=false` is an idempotent peek — the server keeps the current
--- challenge per (strategy, language), so re-running returns the SAME kata.
--- `dequeue=true` pops the queue. A changed token or response shape surfaces
--- through the drift error in _parse — never silently.
---
--- The queue advances ONLY on dequeue=true. Solving a kata does not move it,
--- so a solved kata sits at the head forever unless something pops it. Two
--- things do: cmd.focus_kata_completed (after a finalize) and the completed
--- self-heal in resolve_head below.
trainer.STRATEGIES = {
    fundamentals = "reference_workout",
    rank_up = "default",
    practice_and_repeat = "retrain_workout",
    beta = "beta_workout",
    -- "random" is intentionally absent: Focus→Random resolves client-side
    -- via problemlist_utils.random_for_lang (eng review decision #7).
    -- (A server-side "random" token also exists if that ever changes.)
}

--- Categories whose whole point is re-serving kata you already solved.
--- The completed self-heal must never touch these.
local SERVES_COMPLETED = { practice_and_repeat = true }

-- Bound on the self-heal loop: a queue of nothing but solved kata must not
-- turn one :CW focus into unbounded requests.
local MAX_AUTO_ADVANCE = 3

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

--- Has this kata already been completed? Reads the completed cache, which
--- also covers kata solved on the website or another machine.
--- Overridable in tests.
---@param kata { slug: string, id: string? }
---@return boolean
function trainer._is_completed(kata)
    if not kata then return false end
    local ok, completed_cache = pcall(require, "codewars.cache.completed")
    if not ok then return false end
    local got, items = pcall(completed_cache.get)
    if not got or type(items) ~= "table" then return false end

    local keys = {}
    if kata.slug then keys[kata.slug] = true end
    if kata.id then keys[kata.id] = true end
    for _, item in ipairs(items) do
        if (item.slug and keys[item.slug]) or (item.id and keys[item.id]) then
            return true
        end
    end
    return false
end

-- One fetch at a time: dequeue advances the server-side focus queue, so a
-- second in-flight request would double-pop and race the mounts.
local pending = false

---@param strategy string
---@param language string
---@param dequeue boolean
---@return string endpoint
local function peek_endpoint(strategy, language, dequeue)
    return ("/trainer/peek/%s/%s?dequeue=%s"):format(language, strategy, dequeue and "true" or "false")
end

--- One trainer request, parsed. Maps 404 to a language-support message.
---@param cb fun(kata: { slug: string, id: string? }?, err: cw.err?)
local function request(category, strategy, language, dequeue, cb)
    api_utils.get(peek_endpoint(strategy, language, dequeue), {
        -- A pop mutates server state, so the shared 5xx retry default would
        -- silently skip kata. An idempotent peek keeps it.
        retry = dequeue and 0 or nil,
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

--- Peek the queue head, popping past kata that are already completed.
--- The queue only advances on dequeue, so without this a kata solved in a
--- previous session stays at the head forever.
local function resolve_head(category, strategy, language, finish)
    local advanced = 0

    local function peek_head()
        request(category, strategy, language, false, function(kata, err)
            if err then return finish(nil, err) end

            local stale = not SERVES_COMPLETED[category]
                and advanced < MAX_AUTO_ADVANCE
                and trainer._is_completed(kata)
            if not stale then
                return finish(kata)
            end

            advanced = advanced + 1
            log.debug(("focus: '%s' is already completed, advancing the %s queue"):format(
                tostring(kata.slug), category))
            request(category, strategy, language, true, function(_, perr)
                if perr then return finish(nil, perr) end
                peek_head()
            end)
        end)
    end

    peek_head()
end

---@return string? strategy, cw.err? err
local function strategy_for(category)
    local strategy = trainer.STRATEGIES[category]
    if not strategy then
        return nil, { msg = ("Unknown focus category: %s"):format(tostring(category)) }
    end
    return strategy
end

--- Fetch the current kata for a focus category + language.
--- Idempotent for an unsolved kata: the server owns the focus pointer, so
--- re-running returns the same kata until it is solved or skipped.
---@param category string plugin-internal key (see picker.focus_categories)
---@param language string
---@param cb fun(kata: { slug: string, id: string? }?, err: cw.err?)
function trainer.next_kata(category, language, cb)
    local strategy, serr = strategy_for(category)
    if serr then return cb(nil, serr) end

    if pending then
        return cb(nil, { msg = "Already fetching a focus kata..." })
    end
    pending = true

    resolve_head(category, strategy, language, function(kata, err)
        pending = false
        cb(kata, err)
    end)
end

--- Skip the current kata: pop the queue, then resolve the new head. The
--- follow-up peek makes the result deterministic regardless of whether the
--- pop returns the old or the new head.
---@param category string
---@param language string
---@param cb fun(kata: { slug: string, id: string? }?, err: cw.err?)
function trainer.skip(category, language, cb)
    local strategy, serr = strategy_for(category)
    if serr then return cb(nil, serr) end

    if pending then
        return cb(nil, { msg = "Already fetching a focus kata..." })
    end
    pending = true

    request(category, strategy, language, true, function(_, err)
        if err then
            pending = false
            return cb(nil, err)
        end
        resolve_head(category, strategy, language, function(kata, rerr)
            pending = false
            cb(kata, rerr)
        end)
    end)
end

--- Pop the queue without opening anything. Called after a focus kata is
--- finalized: completing a kata does not move the server's pointer, so
--- without this the next :CW focus re-serves the kata you just solved.
---@param category string
---@param language string
---@param cb? fun(err: cw.err?)
function trainer.advance(category, language, cb)
    cb = cb or function() end

    local strategy, serr = strategy_for(category)
    if serr then return cb(serr) end

    if pending then
        return cb({ msg = "Already fetching a focus kata..." })
    end
    pending = true

    request(category, strategy, language, true, function(_, err)
        pending = false
        cb(err)
    end)
end

return trainer
