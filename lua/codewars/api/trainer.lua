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

--- Build a slug/id lookup of the kata completed IN THIS LANGUAGE.
---
--- Completion on Codewars is per-language: solving a kata in Python does not
--- complete it in JavaScript. This set decides whether the self-heal pops the
--- queue head, and a pop is irreversible — so a language-blind set would burn
--- a kata the user has never attempted in the language they are training.
--- An entry with no `completedLanguages` (older cache writes) is treated as
--- NOT completed here: failing toward "leave it alone" costs the user a
--- manual `:CW focus skip`, while failing the other way destroys a kata.
---
--- Reading the cache is a file read plus a JSON decode, and the self-heal can
--- ask up to MAX_AUTO_ADVANCE+1 times per focus, so resolve_head builds this
--- ONCE and passes it down rather than re-reading per iteration.
---@param language string
---@return table<string, boolean>? nil when the cache is unavailable
function trainer._completed_keys(language)
    local ok, completed_cache = pcall(require, "codewars.cache.completed")
    if not ok then return nil end
    local got, items = pcall(completed_cache.get)
    if not got or type(items) ~= "table" then return nil end

    local keys = {}
    for _, item in ipairs(items) do
        local langs = item.completedLanguages
        if type(langs) == "table" and vim.tbl_contains(langs, language) then
            if item.slug then keys[item.slug] = true end
            if item.id then keys[item.id] = true end
        end
    end
    return keys
end

--- Has this kata already been completed? Covers kata solved on the website
--- or another machine, since it reads the same completed cache.
--- Overridable in tests.
---@param kata { slug: string, id: string? }
---@param keys table<string, boolean>? prebuilt lookup; read fresh when absent
---@return boolean
function trainer._is_completed(kata, keys)
    if not kata then return false end
    keys = keys or trainer._completed_keys()
    if not keys then return false end
    return (kata.slug ~= nil and keys[kata.slug] == true)
        or (kata.id ~= nil and keys[kata.id] == true)
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
                    -- Keep the server's own reason: a 404 here can equally be
                    -- an empty queue or a drifted strategy token, and throwing
                    -- the original away makes real drift look like a language
                    -- problem.
                    err = {
                        status = 404,
                        msg = ("No %s kata available for %s — the trainer may not support this language. (server said: %s)"):format(
                            category, language, tostring(err.msg)
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

--- Do two trainer responses name the same kata? The endpoint returns an id
--- for some shapes and a slug for others, so compare across both fields.
---@return boolean
local function same_kata(a, b)
    if not a or not b then return false end
    for _, key in ipairs({ a.slug, a.id }) do
        if key ~= nil and (key == b.slug or key == b.id) then return true end
    end
    return false
end

--- Peek the queue head, popping past kata that are already completed.
--- The queue only advances on dequeue, so without this a kata solved in a
--- previous session stays at the head forever.
local function resolve_head(category, strategy, language, finish)
    local advanced = 0
    -- Read the completed cache once per resolve, not once per iteration.
    -- `or {}` keeps it a table even when the cache is unavailable, so
    -- _is_completed never falls back to re-reading it per iteration.
    local completed_keys = {}
    if not SERVES_COMPLETED[category] then
        completed_keys = trainer._completed_keys(language) or {}
    end

    local judge

    --- Resolve the current head, then judge it.
    --- @param known table? a head already fetched, so we do not re-peek it
    local function peek_head(known)
        if known then return judge(known) end
        request(category, strategy, language, false, judge)
    end

    --- Decide whether the head is servable or must be advanced past.
    ---@param kata table?
    ---@param err table?
    judge = function(kata, err)
            if err then return finish(nil, err) end

            -- The SERVES_COMPLETED check is deliberately repeated here even
            -- though those categories carry an empty key set. This guards a
            -- DESTRUCTIVE dequeue, so the reason a category never advances
            -- belongs at the decision, not implied by an empty table.
            local solved = not SERVES_COMPLETED[category]
                and trainer._is_completed(kata, completed_keys)
            if not solved then
                return finish(kata)
            end

            if advanced >= MAX_AUTO_ADVANCE then
                -- Out of budget with a solved kata still at the head. Serve
                -- it rather than erroring, but say so — silently reopening a
                -- finished kata is the bug this whole path exists to fix.
                log.warn(("This %s kata is already completed. Run :CW focus skip to advance the queue."):format(category))
                return finish(kata)
            end

            advanced = advanced + 1
            log.debug(("focus: '%s' is already completed, advancing the %s queue"):format(
                tostring(kata.slug), category))
            local dropped = kata
            request(category, strategy, language, true, function(_, perr)
                if perr then return finish(nil, perr) end
                -- The pop's own response shape is not something we can rely
                -- on (it may echo the old head or the new one), so verify by
                -- re-peeking and checking the head actually MOVED. If it did
                -- not, the pop had no effect — keep popping and we would just
                -- burn requests, or worse, destroy kata once it starts
                -- working again. Stop and hand back what is there.
                request(category, strategy, language, false, function(next_head, nerr)
                    if nerr then return finish(nil, nerr) end
                    if same_kata(next_head, dropped) then
                        log.warn(("The %s queue did not advance past a kata you have already completed. Run :CW focus skip to move it manually."):format(category))
                        return finish(next_head)
                    end
                    peek_head(next_head)
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
---
--- Peeks first and pops ONLY if the head is still `expected`. The pop is
--- irreversible and nothing here is atomic, so if the queue moved in the
--- meantime — solved on the website, advanced by another Neovim — a blind
--- pop would destroy an unrelated, unsolved kata. Confirming the head first
--- shrinks that window to a single round-trip instead of the whole span
--- between opening a kata and finishing it, which can be hours.
---@param category string
---@param language string
---@param expected table? { slug?, id? } the kata this advance is retiring
---@param cb? fun(err: cw.err?)
function trainer.advance(category, language, expected, cb)
    cb = cb or function() end

    local strategy, serr = strategy_for(category)
    if serr then return cb(serr) end

    if pending then
        return cb({ msg = "Already fetching a focus kata..." })
    end
    pending = true

    request(category, strategy, language, false, function(head, err)
        if err then
            pending = false
            return cb(err)
        end

        if expected and not same_kata(head, expected) then
            pending = false
            log.debug(("focus: %s queue head is '%s', not the finished '%s' — not advancing"):format(
                category, tostring(head and head.slug), tostring(expected.slug or expected.id)))
            return cb(nil)
        end

        request(category, strategy, language, true, function(_, perr)
            pending = false
            cb(perr)
        end)
    end)
end

return trainer
