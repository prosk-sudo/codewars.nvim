local config = require("codewars.config")
local log = require("codewars.logger")
local cache_utils = require("codewars.cache.utils")

---@class cw.Cache.Completed
local completed = {}

local function list_file() return cache_utils.cache_file("completed.json") end
local function details_file() return cache_utils.cache_file("kata_details.json") end

--- The completed kata on disk, whether they are stale, and whether they are
--- a list at all: `is_fetched` is true when a full fetch from Codewars ever
--- completed, however long ago and whether it found kata or none. `mark`
--- saves a kata solved before that with a timestamp of 0, so a cache holding
--- only kata marked locally is never fetched: it is a few kata, not the
--- account's list, and nothing that judges by the whole list may trust it.
--- (A list that is fetched and then has kata marked into it still is.)
---@return table[] items
---@return boolean is_stale
---@return boolean is_fetched
function completed.get()
    local raw = cache_utils.read_json(list_file())
    if not raw or not raw.items then return {}, true, false end
    local stamp = raw.timestamp or 0
    local age = os.time() - stamp
    -- Its own interval: the problem list can sit for weeks, but kata solved
    -- on the website should show as completed here within a day.
    local stale = age > (config.user.cache.completed_interval or 86400)
    return raw.items, stale, stamp > 0
end

--- Write the list. A write that did not land (a read-only or full cache
--- directory) is reported, not swallowed: the caller says so in its own
--- words, once, and goes on with the list it has in memory rather than
--- reading the disk back: after a failed write the file may hold the old
--- list, or less, or be damaged (the write is in place).
---@param data table[]
---@param timestamp integer? keep an existing stamp instead of "now"
---@return boolean saved
---@return string? err why it did not
function completed.save(data, timestamp)
    return cache_utils.write_json(list_file(), {
        timestamp = timestamp or os.time(),
        items = data,
    }, { quiet = true })
end

--- Kata details that were looked up but could not be written to disk, kept
--- here so that what reads the details (the open picker) still sees them. Put
--- back on disk with the next write that lands, and dropped by `clear()`.
---@type table<string, table>
local unsaved_details = {}

--- The kata details: on disk, and any looked up since that could not be written.
---@return table<string, table>
function completed.get_details()
    local on_disk = cache_utils.read_json(details_file()) or {}
    if next(unsaved_details) == nil then return on_disk end
    return vim.tbl_extend("force", on_disk, unsaved_details)
end

--- Write `details` as the whole details cache. A lookup does not save through
--- this -- it would write back a snapshot -- but through `merge_details`.
---@param details table<string, table>
---@return boolean saved
---@return string? err why it did not
function completed.save_details(details)
    return cache_utils.write_json(details_file(), details, { quiet = true })
end

--- Refreshes in flight, by the account each is for, with the callers waiting
--- on it. A refresh is its own table so that one ended after `clear()` has
--- forgotten it cannot free, or answer, the slot of one begun since.
---@type table<string, { callers: function[] }>
local flights = {}

--- Bumped by `clear()`. A refresh begun before it was fetching for a cache
--- that no longer exists, and its reply must not bring that cache back.
local generation = 0

--- What a run that reads or writes the caches began for: the signed-in
--- account and the cache's generation. The caches are that account's, so a
--- run is only entitled to write them while both are still as they were.
---@class cw.Account
---@field username string
---@field generation integer

---@return cw.Account
local function current_account()
    return { username = config.user.username, generation = generation }
end

---@param account cw.Account
---@return boolean
local function is_current(account)
    return config.user.username == account.username and generation == account.generation
end

--- Save kata details a run fetched (`found`, by slug) into the details cache.
--- Every save of details goes through here: what is added is only what the
--- run fetched, to the cache as it is NOW -- never the snapshot the run read
--- when it began, which would erase what another lookup saved since -- and
--- nothing is written for an account or cache that is gone. A write that does
--- not land leaves the names in memory (`unsaved_details`), for the next write
--- to carry along, and is reported to the caller to say so once.
---@param found table<string, table>
---@param account cw.Account what the run began for
---@return "saved"|"unsaved"|"gone" outcome "gone": `account` is gone and nothing was kept
---@return string? err why it was not written
local function merge_details(found, account)
    if not is_current(account) then return "gone" end
    if next(found) == nil then return "saved" end
    local saved, err = completed.save_details(vim.tbl_extend("force", completed.get_details(), found))
    if saved then
        unsaved_details = {}
        return "saved"
    end
    unsaved_details = vim.tbl_extend("force", unsaved_details, found)
    return "unsaved", err
end

--- Remove both caches. The completed list is the signed-in user's, so it
--- must not outlive their cookie; the kata details are not per-user but
--- are only ever rebuilt from the list, so they go too. A refresh already on
--- its way is for the cookie that is gone: it is dropped when its reply
--- lands, and a refresh asked for from now on is a new one.
function completed.clear()
    generation = generation + 1
    flights = {}
    unsaved_details = {}
    for _, f in ipairs({ list_file(), details_file() }) do
        if f:exists() then pcall(f.rm, f) end
    end
end

--- `item`, a kata as the server described it, with the languages `mark`
--- added to the cached copy that the server does not list yet. `local_langs`
--- then holds just those: once the server lists a language it leaves it, and
--- with none left the field is gone. An item with nothing pending comes back
--- as it is.
---@param item table
---@param local_langs string[]?
---@return table
local function with_pending_languages(item, local_langs)
    local have = item.completedLanguages or {}
    local pending = vim.tbl_filter(function(lang)
        return not vim.tbl_contains(have, lang)
    end, local_langs or {})
    if #pending == 0 then return item end
    return vim.tbl_extend("force", item, {
        completedLanguages = vim.list_extend(vim.list_slice(have), pending),
        local_langs = pending,
    })
end

--- The refreshed list, plus what was marked locally while its request was out
--- and so is not in the reply: a kata it lacks altogether, and a language it
--- does not list yet for a kata it has. Neither is un-completed until the
--- server has caught up.
---@param fetched table[] the reply's items
---@param cached table[] the cache as it is now
---@return table[]
local function merge_local_marks(fetched, cached)
    local pending_langs, seen = {}, {}
    for _, item in ipairs(cached) do
        pending_langs[item.id] = item.local_langs
    end
    local merged = {}
    for _, item in ipairs(fetched) do
        seen[item.id] = true
        merged[#merged + 1] = with_pending_languages(item, pending_langs[item.id])
    end
    for _, item in ipairs(cached) do
        if item.local_mark and not seen[item.id] then
            table.insert(merged, 1, item)
        end
    end
    return merged
end

--- Refresh the list from Codewars, and hand `cb` the kata and any error.
---
--- One refresh runs at a time per account: a call made while one is in flight
--- sends no request and gets that refresh's result when it ends, an error
--- included. Two replies merged one after the other race -- the newer one
--- can clear a marker that the older, arriving later, still needed.
---
--- The cache on disk is the signed-in account's, so a reply is only merged
--- and saved while that account is still the one the refresh began for and
--- the cache has not been cleared since; otherwise it is dropped and the
--- callers get an error.
---@param cb? function
function completed.update(cb)
    local api_utils = require("codewars.api.utils")
    local urls = require("codewars.api.urls")
    local account = current_account()
    local username = account.username

    if username == "" then
        -- The username is never configured by hand: it is detected from the
        -- dashboard when the menu opens. Empty here means that detection
        -- failed, so say that instead of implying a missing setting.
        log.warn("Codewars username not detected yet. Open :CW menu to retry, "
            .. "or run :CW cookie if your session expired.")
        if cb then cb({}) end
        return
    end

    local flight = flights[username]
    if flight then
        flight.callers = vim.list_extend(vim.list_slice(flight.callers), { cb })
        return
    end
    flight = { callers = { cb } }
    flights[username] = flight

    local all = {}
    local page = 0
    local settled = false

    --- End the refresh: free the slot first, so that whatever a callback does
    --- starts a fresh one, then answer everyone who asked. Whichever way it
    --- ends, this is the one exit.
    local function settle(items, err)
        if settled then return end
        settled = true
        if flights[username] == flight then flights[username] = nil end
        for _, caller in ipairs(flight.callers) do
            local ok, failure = pcall(caller, items, err)
            if not ok then log.error("A completed-kata refresh callback failed: " .. tostring(failure)) end
        end
    end

    --- Nothing is saved on any of these: the cached list stays as it was and
    --- the next open retries.
    local function give_up(err)
        settle((completed.get()), err)
    end

    local fetch_page

    local function on_page(res, err)
        if not is_current(account) then
            -- Checked before anything is read from the reply, and on every
            -- page, so a refresh for an account that is gone neither writes
            -- over the cache that is there now, nor merges that account's
            -- local marks into this list, nor goes on asking for pages.
            return give_up({
                msg = "The account changed while your completed kata were being fetched; keeping the cached list.",
            })
        end

        if err then
            -- Writing the pages fetched so far would stamp a partial list as
            -- fresh and overwrite a valid older cache, so kata completed on
            -- later pages would show as unsolved until the cache interval
            -- expired. Hand back whatever is on disk.
            log.err(err)
            return give_up(err)
        end

        if not (type(res) == "table" and type(res.data) == "table") then
            -- A 2xx without `data` is not "no completed kata": it is a reply
            -- we do not understand (interstitial, drift). Saving `all` here
            -- overwrote a valid cache with a fresh-stamped empty or partial
            -- list.
            local bad = { msg = "Unexpected reply from the completed-kata API; keeping the cached list." }
            log.err(bad)
            return give_up(bad)
        end

        vim.list_extend(all, res.data)
        if res.totalPages and page < res.totalPages - 1 then
            page = page + 1
            return fetch_page()
        end

        -- A kata marked complete locally while this refresh was in flight is
        -- not in the fetched pages yet; keep it rather than un-completing it
        -- until the next refresh. Read now, not when the refresh began: a
        -- kata marked since then is in the cache and not in this reply.
        all = merge_local_marks(all, (completed.get()))
        local saved, save_err = completed.save(all)
        if not saved then
            -- The fetch worked: its callers get the list, from memory. The
            -- disk may hold something else (the old list, only the kata marked
            -- here, or a file the failed write damaged), so say that this did
            -- not stick.
            log.warn(("Fetched your completed kata, but could not save them (%s); "
                .. "using the fetched list for now."):format(tostring(save_err or "the write failed")))
        end
        log.info(("Fetched %d completed kata"):format(#all))
        settle(all)
    end

    --- A failure in here (a cache that cannot be written, a request that
    --- cannot start) must still end the refresh, or no later one could run.
    local function guarded(fn, ...)
        local ok, failure = pcall(fn, ...)
        if ok then return end
        local msg = "Could not refresh your completed kata: " .. tostring(failure)
        log.error(msg)
        give_up({ msg = msg })
    end

    function fetch_page()
        local endpoint = urls.completed:format(username, page)
        api_utils.get(endpoint, {
            callback = function(res, err) guarded(on_page, res, err) end,
        })
    end

    guarded(fetch_page)
end

--- Save the list `mark` made, telling the user when it did not land: a kata
--- they just solved is then not recorded as completed until the next refresh.
---@param items table[]
---@param timestamp integer
local function save_marked(items, timestamp)
    local saved, err = completed.save(items, timestamp)
    if not saved then
        log.warn(("Could not record that you completed this kata (%s); "
            .. "it shows as completed again after the next refresh."):format(tostring(err or "the write failed")))
    end
end

--- Locally mark a kata as completed (no API call).
---@param kata_id string
---@param slug string?
---@param lang string?
function completed.mark(kata_id, slug, lang)
    -- Raw, not get(): a missing or expired cache must stay missing or
    -- expired. Stamping a one-item list "now" made a partial cache look
    -- complete and fresh for a whole cache interval.
    local raw = cache_utils.read_json(list_file()) or {}
    local items = raw.items or {}
    for i, item in ipairs(items) do
        if item.id == kata_id then
            -- Already there, but a second language is a completion of its
            -- own: without it the kata's solution in that language would
            -- keep showing as unfinished until the next refresh.
            local langs = item.completedLanguages or {}
            if not lang or vim.tbl_contains(langs, lang) then return end
            -- Remembered as added here too, for a refresh whose reply was
            -- made before the submit and so does not list it yet.
            local updated = vim.tbl_extend("force", item, {
                completedLanguages = vim.list_extend(vim.list_slice(langs), { lang }),
                local_langs = vim.list_extend(vim.list_slice(item.local_langs or {}), { lang }),
            })
            local with_language = vim.list_slice(items)
            with_language[i] = updated
            save_marked(with_language, raw.timestamp or 0)
            return
        end
    end
    local marked = {
        id = kata_id,
        slug = slug or kata_id,
        completedLanguages = lang and { lang } or {},
        completedAt = os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
        local_mark = true,
        local_langs = lang and { lang } or nil,
    }
    save_marked(vim.list_extend({ marked }, items), raw.timestamp or 0)
end

--- Kata one call looks up at once. About 60 requests a minute is what
--- Codewars lets through, so more than this in one burst is asking for a 429.
local FIRST_BATCH = 50

--- Names found past the first batch are saved, and the caller told, this
--- many at a time rather than one write each.
local REST_SAVE_EVERY = 5

---@class cw.EnrichOpts
---@field names boolean? look a kata up again when its cached details have no name
---@field keep_going (fun(): boolean)? when given, the kata past the first batch are looked up too, one at a time at the kata-list build's pace, for as long as this returns true -- checked before every request
---@field on_progress fun()? called after names found past the first batch are saved, so the caller can show them

--- Look up `slugs`, the kata an `enrich` call had no room for in its first
--- batch, one at a time. Paced and backed off the way the kata-list build is
--- (problemlist's pace, cooldown and pacer), and saved as they arrive.
---
--- Stops before the next request when its caller no longer wants the names
--- (`keep_going` false), keeping what it has; and when the account changed or
--- the cache was cleared since `account` (what the whole `enrich` call began
--- for, the first batch included), saving nothing more: what it holds then
--- belongs to a cache that is gone.
---@param slugs string[]
---@param opts cw.EnrichOpts
---@param account cw.Account
---@param warn_unsaved fun(why: string?) tells the user, once for the whole call, that names could not be saved
local function look_up_rest(slugs, opts, account, warn_unsaved)
    --- Why the run should not go on, if so: "gone" for an account or cache
    --- that is not the one it began for, "closed" for a caller that is done.
    local function stop_reason()
        if not is_current(account) then return "gone" end
        local ok, wanted = pcall(opts.keep_going)
        if not (ok and wanted) then return "closed" end
    end
    if stop_reason() then return end

    local problemlist = require("codewars.cache.problemlist")
    local kata_api = require("codewars.api.kata")
    local total = #slugs
    local next_slug, refusals, failed, looked_up = 1, 0, 0, 0
    local pace_ms = problemlist.PACE_MS
    local pending = {} ---@type table<string, table> looked up, not yet saved
    local finished = false
    -- The first batch has just gone out: the first of these waits its turn.
    local paced = problemlist.pacer(function() return pace_ms end, function() return finished end,
        (vim.uv or vim.loop).now())
    local spinner = require("codewars.logger.spinner"):start(("Looking up %d more kata names"):format(total))

    local function save_pending()
        if next(pending) == nil then return end
        local to_save = pending
        pending = {}
        local outcome, why = merge_details(to_save, account)
        -- Nothing is written, and nobody told, for an account that is gone.
        if outcome == "gone" then return end
        -- Unsaved names are still in memory for the caller to show.
        if outcome == "unsaved" then warn_unsaved(why) end
        if not opts.on_progress then return end
        local ok, failure = pcall(opts.on_progress)
        if not ok then log.error("Kata name lookup progress callback failed: " .. tostring(failure)) end
    end

    --- The one way out. `outcome`: "done", "limited" (refused too often in a
    --- row), "broke" (an error of our own), or the stop_reason it stopped for.
    local function finish(outcome, failure)
        if finished then return end
        finished = true
        save_pending()
        if outcome == "done" and failed == 0 then
            spinner:success(("Looked up %d kata names"):format(looked_up))
        elseif outcome == "done" then
            spinner:error(("Looked up %d of %d kata names; the rest are tried again next time"):format(looked_up, total))
        elseif outcome == "limited" then
            spinner:error(("Rate limited by Codewars — %d of %d kata names looked up; the rest fill in next time"):format(
                looked_up, total))
        elseif outcome == "broke" then
            log.error("Kata name lookup failed: " .. tostring(failure))
            spinner:error("Could not look up the rest of the kata names")
        else
            spinner:success(("Stopped looking up kata names (%d of %d done)"):format(looked_up, total))
        end
    end

    local step

    local function on_reply(slug, res, err)
        if finished then return end
        local reason = stop_reason()
        if reason == "gone" then return finish("gone") end

        if err and err.rate_limited then
            if reason then return finish(reason) end
            refusals = refusals + 1
            if refusals > problemlist.MAX_COOLDOWNS then return finish("limited") end
            -- Wait the limiter out, then ask for the SAME kata at a slower pace.
            local wait = problemlist.cooldown_ms(refusals)
            pace_ms = problemlist.slower(pace_ms)
            spinner:update(("Rate limited by Codewars — resuming in %ds (%d of %d looked up)"):format(
                math.floor(wait / 1000), looked_up, total))
            return vim.defer_fn(step, wait)
        end

        refusals = 0
        if err or not res then
            failed = failed + 1
        else
            pending = vim.tbl_extend("force", pending, { [slug] = { rank = res.rank, tags = res.tags, name = res.name } })
            looked_up = looked_up + 1
        end
        next_slug = next_slug + 1
        if vim.tbl_count(pending) >= REST_SAVE_EVERY then save_pending() end
        if reason then return finish(reason) end
        if next_slug > total then return finish("done") end
        spinner:update(("Looking up kata names (%d of %d)"):format(next_slug - 1, total))
        step()
    end

    function step()
        if finished then return end
        local reason = stop_reason()
        if reason then return finish(reason) end
        paced(function()
            local again = stop_reason()
            if again then return finish(again) end
            local slug = slugs[next_slug]
            -- The refusals are this run's to wait out, not the request
            -- layer's: its own retries would spend the window's slots.
            local ok, failure = pcall(kata_api.get, slug, function(res, err)
                local handled, broke = pcall(on_reply, slug, res, err)
                if not handled then finish("broke", broke) end
            end, { retry_rate_limited = false, cancelled = function() return finished end })
            if not ok then finish("broke", failure) end
        end)
    end

    step()
end

--- Enrich completed kata with rank/tag details.
---
--- Details cached before names were kept hold a rank and tags and no name.
--- :CW completed has no use for the name and leaves them be; a caller that
--- names kata from them (:CW unfinished) asks with `names`.
---
--- At most FIRST_BATCH kata are looked up at once. A caller that gives
--- `keep_going` has the rest looked up after them, in the background, while
--- it stays true; the others get the first batch only.
---@param items table[]
---@param cb function callback(enriched_items)
---@param opts cw.EnrichOpts?
function completed.enrich(items, cb, opts)
    -- What the whole call, the first batch and the rest after it, is for:
    -- captured once, here, and checked wherever it reads a reply or writes.
    local account = current_account()
    -- What is cached now, to tell what is missing and to fill `items` in. It
    -- is a snapshot: it is never written back, only what this run fetches is
    -- added to the cache (merge_details).
    local details = completed.get_details()
    local need_names = opts and opts.names
    local missing = {}

    for _, item in ipairs(items) do
        local slug = item.slug or item.id
        if not slug then goto continue end
        local cached = details[slug]
        if cached and (cached.name or not need_names) then
            item.rank = cached.rank
            item.tags = cached.tags
        else
            table.insert(missing, slug)
        end
        ::continue::
    end

    if #missing == 0 then
        return cb(items)
    end

    -- Fetch missing details (limit to FIRST_BATCH, 5 concurrent)
    local total = math.min(#missing, FIRST_BATCH)
    local fetched = 0
    local failed = 0
    local rate_limited = false
    local concurrent = 0
    local max_concurrent = 5
    local idx = 0
    local found = {} ---@type table<string, table> what this run fetched, by slug
    local done = false
    local warned = false
    --- Said once for the whole call, not once per batch of names.
    local function warn_unsaved(why)
        if warned then return end
        warned = true
        log.warn(("Could not save the kata details (%s); the names found are kept for this session only.")
            :format(tostring(why or "the write failed")))
    end

    local Spinner = require("codewars.logger.spinner")
    local spinner = Spinner:start(("Fetching kata details (0/%d)"):format(total))

    --- The account changed or the cache was cleared while the requests were
    --- out: what they bring belongs to a cache that is gone. Nothing is saved,
    --- no more are sent, the rest is not started, and the caller is told the
    --- way update tells its callers -- with the items it was given and an
    --- error -- so that it does not show a list for an account that is gone.
    local function abandon()
        done = true
        spinner:success("Stopped fetching kata details: the account changed")
        cb(items, { msg = "The account changed while kata details were being fetched; nothing was saved." })
    end

    local function fetch_next()
        while not done and concurrent < max_concurrent and idx < total do
            if not is_current(account) then return abandon() end
            idx = idx + 1
            concurrent = concurrent + 1
            local slug = missing[idx]
            local kata_api = require("codewars.api.kata")
            kata_api.get(slug, function(res, err)
                if done then return end
                if not is_current(account) then return abandon() end
                concurrent = concurrent - 1
                fetched = fetched + 1

                spinner:update(("Fetching kata details (%d/%d)"):format(fetched, total))

                if not err and res then
                    -- The name too: :CW unfinished lists kata the catalogue
                    -- does not hold, and has nothing else to call them by.
                    found = vim.tbl_extend("force", found, { [slug] = { rank = res.rank, tags = res.tags, name = res.name } })
                else
                    failed = failed + 1
                    rate_limited = rate_limited or (err and err.rate_limited) or false
                end

                if fetched >= total then
                    local outcome, why = merge_details(found, account)
                    if outcome == "gone" then return abandon() end
                    if outcome == "unsaved" then warn_unsaved(why) end
                    done = true
                    if failed == 0 then
                        spinner:success(("Fetched %d kata details"):format(total))
                    else
                        -- Honest count: the ones that failed are still
                        -- missing and will be retried on the next open.
                        spinner:error(("Fetched %d of %d kata details%s"):format(
                            total - failed, total, rate_limited and " (rate limited — try again later)" or ""))
                    end
                    local known = vim.tbl_extend("force", details, found)
                    for _, item in ipairs(items) do
                        local s = item.slug or item.id
                        if known[s] then
                            item.rank = known[s].rank
                            item.tags = known[s].tags
                        end
                    end
                    -- Before the callback, so that nothing it does can keep
                    -- the rest from starting; the first of them waits a pace.
                    if opts and type(opts.keep_going) == "function" and #missing > FIRST_BATCH then
                        look_up_rest(vim.list_slice(missing, FIRST_BATCH + 1), opts, account, warn_unsaved)
                    end
                    cb(items)
                else
                    fetch_next()
                end
            end)
        end
    end

    fetch_next()
end

return completed
