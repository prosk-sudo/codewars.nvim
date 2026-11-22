local config = require("codewars.config")
-- vim.uv arrived in 0.10; the plugin still supports 0.9.
local uv = vim.uv or vim.loop
local cache_utils = require("codewars.cache.utils")

---@class cw.Cache.Problemlist
local problemlist = {}

local function cache_file()
    return cache_utils.cache_file("problemlist.json")
end

--- Ranks an unfinished build has already fetched in full. Kept apart from
--- problemlist.json on purpose: that file must only ever hold a complete
--- list, because a short one stamped with `now` looks fresh for the whole
--- cache interval and hides every kata it is missing.
local function checkpoint_file()
    return cache_utils.cache_file("problemlist.partial.json")
end

local DEFAULT_INTERVAL = 30 * 24 * 60 * 60

---@return integer seconds after which the list counts as stale
local function interval()
    return (config.user.cache or {}).update_interval or DEFAULT_INTERVAL
end

-- Codewars publishes no rate limit. Measured (2026-11): the search endpoint
-- answers 429 once ~60 requests land inside a rolling minute, sends no
-- Retry-After, and lets requests through again a few seconds later. A full
-- build is ~290 pages, so it cannot outrun that limit and has to stay under
-- it instead. The old four-wide batches ran at ~3 requests a second, hit the
-- wall ~60 pages in on every attempt, and threw the run away -- so nothing
-- was ever cached and every :CW list started over. One request per PACE_MS
-- is ~55 a minute: about five minutes for the whole catalogue, and it ends.
problemlist.PACE_MS = 1100
--- Ceiling for the pace once 429s have slowed it down.
problemlist.MAX_PACE_MS = 2000
--- After a 429 the build waits this long, doubling up to MAX_COOLDOWN_MS,
--- then asks for the same page again rather than abandoning the run.
problemlist.COOLDOWN_MS = 15000
problemlist.MAX_COOLDOWN_MS = 60000
--- Consecutive refusals before giving up: 15+30+60+60s is four minutes of a
--- server that will not let a single page through.
problemlist.MAX_COOLDOWNS = 4

--- Wait after the `refusals`-th 429 in a row: COOLDOWN_MS doubling, up to MAX_COOLDOWN_MS.
---@param refusals integer
---@return integer ms
function problemlist.cooldown_ms(refusals)
    return math.floor(math.min(problemlist.COOLDOWN_MS * 2 ^ (refusals - 1), problemlist.MAX_COOLDOWN_MS))
end

--- The pace after a 429: a quarter slower, up to MAX_PACE_MS.
---@param pace_ms integer
---@return integer ms
function problemlist.slower(pace_ms)
    return math.min(math.floor(pace_ms * 1.25), problemlist.MAX_PACE_MS)
end

--- Runs `paced(fn)` no sooner than `pace_ms()` after the previous start. Always deferred, so a
--- synchronous callback cannot recurse; once `cancelled()`, even waiting requests are not sent.
---@param pace_ms fun(): integer read each time, so a run can slow down
---@param cancelled fun(): boolean
---@param since integer? when the previous request started (uv.now()), if one just did
---@return fun(fn: function)
function problemlist.pacer(pace_ms, cancelled, since)
    local last_start = since
    return function(fn)
        local wait = 0
        if last_start then
            wait = math.max(0, last_start + pace_ms() - uv.now())
        end
        vim.defer_fn(function()
            if cancelled() then return end
            last_start = uv.now()
            fn()
        end, wait)
    end
end

--- The cached list, and whether it is older than `cache.update_interval`.
--- A stale list is still returned: the catalogue changes slowly and a full
--- rebuild takes minutes, so callers show what they have and refresh in the
--- background (`refresh_if_stale`) rather than block on it.
---@return table[]? items nil only when nothing is cached
---@return boolean stale
---@return integer? age seconds since the list was built
function problemlist.get()
    local data = cache_utils.read_json(cache_file())
    if not data or not data.items then return nil, true, nil end

    local age = os.time() - (data.timestamp or 0)
    return data.items, age > interval(), age
end

---@class cw.Cache.ProblemlistBuild
---@field waiters fun(items: table[], partial: boolean?)[]
---@field found integer kata collected so far

--- The build in flight, if any. There is only ever one: a second build
--- would double the request rate and walk both straight into the limiter.
---@type cw.Cache.ProblemlistBuild?
local build = nil

--- Kata collected so far when a build is running, nil otherwise.
---@return integer?
function problemlist.building()
    return build and build.found or nil
end

local DEFAULT_CHECK_INTERVAL = 24 * 60 * 60

---@return integer seconds between looks for new and changed kata
local function check_interval()
    return (config.user.cache or {}).check_interval or DEFAULT_CHECK_INTERVAL
end

--- Pages of the "Newest" listing one look reads at most. A day's worth of
--- new and changed kata fits in one or two; past this many, whatever is
--- older is left to the next full rebuild.
problemlist.CHECK_MAX_PAGES = 5

--- Whether two entries for the same kata differ in what the list shows.
--- Satisfaction moves with every vote: it is carried along, but counting it
--- would read every look to its page limit.
local function differs(old, new)
    if old.name ~= new.name or old.rank_id ~= new.rank_id then return true end
    local before, after = old.languages or {}, new.languages or {}
    if #before ~= #after then return true end
    local had = {}
    for _, lang in ipairs(before) do had[lang] = true end
    for _, lang in ipairs(after) do
        if not had[lang] then return true end
    end
    return false
end

--- Said once when a run is over, not once per page: result blocks the
--- search parser could not read are left out of what the run collected.
---@param count integer
local function warn_dropped(count)
    if count <= 0 then return end
    require("codewars.logger").warn(
        ("%d kata on the search pages could not be read and were left out"
            .. " — the site markup may have changed"):format(count)
    )
end

local checking = false

--- Merge in the kata published or changed since the list was built or last
--- looked at, in the background.
---
--- A full build is ~290 pages under a rate limit -- minutes -- to pick up
--- what is usually a handful of new kata. Codewars' "Newest" listing puts
--- them first, so this reads it until a page, read whole, brings nothing the
--- list does not already have. Kept to CHECK_MAX_PAGES; the full rebuild
--- every `cache.update_interval` still catches anything this misses.
---@return boolean started false when not due, already running, or there is no list
function problemlist.check_for_new()
    if build or checking then return false end
    local data = cache_utils.read_json(cache_file())
    if type(data) ~= "table" or type(data.items) ~= "table" then return false end
    local last = tonumber(data.checked_at) or tonumber(data.timestamp) or 0
    if os.time() - last <= check_interval() then return false end
    checking = true

    local log = require("codewars.logger")
    local search = require("codewars.api.search")
    local items = data.items
    local index = {}
    for i, item in ipairs(items) do
        local key = item.id or item.slug
        if key then index[key] = i end
    end
    local added, updated, dropped = 0, 0, 0

    --- Only a look that finished is recorded: a failed one leaves
    --- checked_at alone, so the next open tries again. So does one that
    --- left blocks out: it merges what it could read, but it has not seen
    --- all of "Newest", and is not a look that found nothing more.
    local function finish(ok)
        checking = false
        warn_dropped(dropped)
        if not ok then return end
        -- A full build that ran meanwhile wrote a newer list; this one,
        -- read before it, would put the old one back.
        local current = cache_utils.read_json(cache_file())
        if build or type(current) ~= "table" or current.timestamp ~= data.timestamp then
            return
        end
        if dropped == 0 then
            data.checked_at = os.time()
        elseif added + updated == 0 then
            return
        end
        cache_utils.write_json(cache_file(), data)
        if added + updated > 0 then
            log.info(("Kata list: %d new, %d updated"):format(added, updated))
        end
    end

    local function look(page)
        search.fetch_page({
            language = "", -- every kata, as the full build has
            order = "sort_date+desc", -- the site's "Newest"
        }, page, function(results, has_more, err, page_dropped)
            if err then
                log.debug("kata list check failed: " .. tostring(err.msg))
                -- Not a failure to retry quietly: the markup moved, so
                -- every look will fail the same way until it is fixed.
                if err.drift then
                    log.warn("Kata list check stopped: the search results could not be read"
                        .. " — the site markup may have changed. Nothing was merged.")
                end
                return finish(false)
            end
            dropped = dropped + (page_dropped or 0)
            local changes = 0
            for _, entry in ipairs(results or {}) do
                local key = entry.id or entry.slug
                local at = key and index[key]
                if key and not at then
                    items[#items + 1] = entry
                    index[key] = #items
                    added, changes = added + 1, changes + 1
                elseif at and differs(items[at], entry) then
                    items[at] = vim.tbl_extend("force", items[at], entry)
                    updated, changes = updated + 1, changes + 1
                end
            end
            -- "Nothing new here" ends the look only for a page that was read
            -- whole. One that left blocks out may have dropped the new kata,
            -- and the next page may hold more that can be read.
            local nothing_new = changes == 0 and (page_dropped or 0) == 0
            if nothing_new or not has_more or page + 1 >= problemlist.CHECK_MAX_PAGES then
                return finish(true)
            end
            vim.defer_fn(function() look(page + 1) end, problemlist.PACE_MS)
        end)
    end

    -- Deferred: the caller is opening a picker and must not wait on this.
    vim.defer_fn(function() look(0) end, 0)
    return true
end

--- Rebuild the list in the background when it is stale; otherwise look for
--- new and changed kata once a day. Returns true when a rebuild was started
--- (or is already running). Silent otherwise.
---@return boolean
function problemlist.refresh_if_stale()
    local items, stale, age = problemlist.get()
    if not items then return false end
    if not stale then
        problemlist.check_for_new()
        return false
    end
    if build then return true end
    local days = math.floor((age or 0) / 86400)
    require("codewars.logger").info(("Problem list is %d days old — refreshing in the background."):format(days))
    problemlist.update({}, function() end)
    return true
end

--- A checkpoint left by an earlier, unfinished build, if it is still young
--- enough to build on.
---@return { timestamp: integer, ranks: table<string, table[]> }?
local function load_checkpoint()
    local data = cache_utils.read_json(checkpoint_file())
    if type(data) ~= "table" or type(data.ranks) ~= "table" then return nil end
    if os.time() - (tonumber(data.timestamp) or 0) > interval() then return nil end
    return data
end

local function remove_checkpoint()
    pcall(os.remove, tostring(checkpoint_file()))
end

--- Fetch fresh problem list by querying each rank separately (all languages).
--- Codewars caps search results at ~48 pages per query, so we fetch per-rank
--- to get full coverage, without a language filter so we get all kata.
---
--- Ranks finished by an earlier run that was cut short are taken from its
--- checkpoint instead of being fetched again. A call made while a build is
--- already running joins it: `cb` fires when that build ends.
---@param opts? table
---@param cb fun(items: table[], partial: boolean?)
---@return boolean started false when the call joined a running build
function problemlist.update(opts, cb)
    cb = cb or function() end
    if build then
        table.insert(build.waiters, cb)
        return false
    end
    local this = { waiters = { cb }, found = 0 }
    build = this

    opts = opts or {}
    local max_pages_per_rank = opts.max_pages or 100
    local search = require("codewars.api.search")

    local Spinner = require("codewars.logger.spinner")
    local spinner = Spinner:start("Updating problem list cache")

    local ranks = { -8, -7, -6, -5, -4, -3, -2, -1 }
    local rank_labels = { [-8]="8 kyu", [-7]="7 kyu", [-6]="6 kyu", [-5]="5 kyu", [-4]="4 kyu", [-3]="3 kyu", [-2]="2 kyu", [-1]="1 kyu" }

    local checkpoint = load_checkpoint()
    local resumed = checkpoint ~= nil
    checkpoint = checkpoint or { timestamp = os.time(), ranks = {} }
    -- What each checkpointed rank's pages dropped, by rank, saved next to its
    -- items: a rank a resume skips is never fetched again, so this is the only
    -- record of what it left out. A checkpoint from before this was kept has
    -- none, and counts as nothing dropped.
    if type(checkpoint.dropped) ~= "table" then checkpoint.dropped = {} end

    -- Result blocks the parser could not read, over every page of the list
    -- this run is building: the ranks taken from the checkpoint included.
    local dropped = 0

    ---@type table<integer, table[]>
    local by_rank = {}
    for _, rank in ipairs(ranks) do
        local saved = checkpoint.ranks[tostring(rank)]
        if type(saved) == "table" and #saved > 0 then
            by_rank[rank] = saved
            this.found = this.found + #saved
            local saved_dropped = tonumber(checkpoint.dropped[tostring(rank)]) or 0
            if saved_dropped > 0 then dropped = dropped + math.floor(saved_dropped) end
        end
    end

    local rank_idx = 0
    local aborted = false
    local pace_ms = problemlist.PACE_MS
    local cooldowns = 0

    -- The rank being fetched and what it has produced so far. Not in
    -- by_rank until it finishes (by_rank is what resumes skip), but an
    -- aborted run still hands these to the caller.
    local current_rank, current_items = nil, nil ---@type integer?, table[]?
    -- What the rank being fetched has dropped so far; saved with it.
    local current_dropped = 0

    local function collected()
        local all = {}
        for _, rank in ipairs(ranks) do
            local items = by_rank[rank] or (rank == current_rank and current_items)
            if items then vim.list_extend(all, items) end
        end
        return all
    end

    ---@param items table[]
    ---@param partial boolean?
    local function deliver(items, partial)
        local waiters = this.waiters
        -- Cleared before any callback runs, so one that throws cannot leave
        -- the module believing a build is still in flight.
        build = nil
        for i, waiter in ipairs(waiters) do
            -- Each joined caller gets its own list: the picker sorts and
            -- filters what it is handed.
            waiter(i == 1 and items or vim.list_slice(items), partial)
        end
    end

    ---@param partial boolean? true when we stopped early and must not
    --- pretend the cache is complete
    local function finish(partial)
        warn_dropped(dropped)

        -- Deduplicate
        local seen = {}
        local unique = {}
        for _, item in ipairs(collected()) do
            local slug = item.slug or item.id
            if not seen[slug] then
                seen[slug] = true
                table.insert(unique, item)
            end
        end

        -- Every page being empty is not "Codewars has no kata": it is an
        -- interstitial page that returned 200, or a markup change that left
        -- no result blocks to notice. A page whose blocks fail to parse is
        -- reported by fetch_page as drift and aborts before getting here, so
        -- this is the backstop for the rest.
        if not partial and #unique == 0 then
            spinner:error("No kata found on any search page — the site markup may have changed; cache left as is.")
            partial = true
        end

        if partial then
            -- Deliberately not written: a short list stamped with `now` would
            -- look fresh for the whole cache interval, quietly hiding the
            -- kata we never fetched. The ranks that did finish are in the
            -- checkpoint, so the next run picks up where this one stopped.
            -- The flag tells the caller not to report success on top of the
            -- failure the spinner already showed.
            deliver(unique, true)
            return
        end

        -- A resumed list is only as new as its oldest rank.
        local ok = cache_utils.write_json(cache_file(), {
            items = unique,
            timestamp = resumed and checkpoint.timestamp or os.time(),
        })
        if ok then remove_checkpoint() end

        spinner:success(("Cached %d kata"):format(#unique))
        deliver(unique)
    end

    local function abort(msg)
        aborted = true
        spinner:error(msg)
        return finish(true)
    end

    --- Run `fn` no sooner than the pace allows since the previous request.
    --- Always deferred, even at zero delay, so a page whose callback fires
    --- synchronously cannot recurse through a whole rank.
    local paced = problemlist.pacer(function() return pace_ms end, function() return aborted end)

    local fetch_rank

    ---@param rank integer
    ---@param page integer
    ---@param items table[] what this rank has produced so far
    local function fetch_page(rank, page, items)
        local label = rank_labels[rank] or tostring(rank)

        local function rank_done()
            -- An empty rank is never checkpointed: if the markup drifted, a
            -- saved "nothing here" would be skipped by every later resume
            -- and the all-empty guard above could never clear.
            if #items > 0 then
                by_rank[rank] = items
                checkpoint.ranks[tostring(rank)] = items
                checkpoint.dropped[tostring(rank)] = current_dropped
                cache_utils.write_json(checkpoint_file(), checkpoint)
            end
            return fetch_rank()
        end

        if page >= max_pages_per_rank then return rank_done() end

        paced(function()
            search.fetch_page({
                language = "", -- no language filter, fetch all kata
                rank = { rank },
                order = "popularity+desc",
                -- The build owns 429 timing (cooldown below). Letting the
                -- request layer also retry would spend the next few slots
                -- of the same window on half-second backoffs.
                retry_rate_limited = false,
                -- Once the run has given up, a 5xx retry still in flight
                -- inside the request layer must not keep going.
                cancelled = function() return aborted end,
            }, page, function(results, has_more, err, page_dropped)
                if aborted then return end

                -- Every abort is partial: writing here would stamp a
                -- truncated list as fresh and hide every kata the aborted
                -- run never reached.
                if err and err.auth then
                    require("codewars.logger").error(err.msg)
                    return abort("Fetch aborted: authentication error")
                end

                if err and err.rate_limited then
                    cooldowns = cooldowns + 1
                    if cooldowns > problemlist.MAX_COOLDOWNS then
                        return abort(("Rate limited by Codewars after %d kata — wait a few minutes and run :CW cache update to continue"):format(this.found))
                    end
                    -- Wait the limiter out, then ask for the SAME page at a
                    -- slower pace. Ending the rank here would truncate it.
                    local wait = problemlist.cooldown_ms(cooldowns)
                    pace_ms = problemlist.slower(pace_ms)
                    spinner:update(("Rate limited by Codewars — resuming in %ds (%d found, %s)"):format(
                        math.floor(wait / 1000), this.found, label))
                    return vim.defer_fn(function()
                        if aborted then return end
                        fetch_page(rank, page, items)
                    end, wait)
                end

                if err and err.drift then
                    -- The page has result blocks and none could be read. It
                    -- is not the end of this rank, and retrying the same
                    -- markup cannot help: stop, and leave the cache as it is.
                    return abort(("Search results could not be read after %d kata — the site markup may have changed; cache left as is."):format(this.found))
                end

                if err then
                    -- Any other failure (5xx after retries, curl could
                    -- not connect, unexpected status). Treating it as an
                    -- empty page would end the rank early and write the
                    -- truncated list as fresh — the same silent hole the
                    -- 429 path above exists to prevent.
                    return abort(("Fetch failed after %d kata: %s"):format(this.found, err.msg or "unknown error"))
                end

                cooldowns = 0
                dropped = dropped + (page_dropped or 0)
                current_dropped = current_dropped + (page_dropped or 0)

                if results and #results > 0 then
                    vim.list_extend(items, results)
                    this.found = this.found + #results
                end

                spinner:update(("Fetching kata (%d found, %s)"):format(this.found, label))

                if not has_more or not results or #results == 0 then
                    return rank_done()
                end
                fetch_page(rank, page + 1, items)
            end)
        end)
    end

    fetch_rank = function()
        rank_idx = rank_idx + 1
        -- Skip what a cut-short earlier run already finished.
        while rank_idx <= #ranks and by_rank[ranks[rank_idx]] do
            rank_idx = rank_idx + 1
        end
        -- An abort has already delivered its partial result; finishing
        -- again here would write the truncated list as complete.
        if aborted then return end
        if rank_idx > #ranks then
            return finish()
        end
        current_rank, current_items, current_dropped = ranks[rank_idx], {}, 0
        fetch_page(current_rank, 0, current_items)
    end

    if resumed then
        spinner:update(("Resuming problem list (%d kata already fetched)"):format(this.found))
    end
    fetch_rank()
    return true
end

function problemlist.delete()
    local f = cache_file()
    if f:exists() then f:rm() end
    remove_checkpoint()
end

return problemlist
