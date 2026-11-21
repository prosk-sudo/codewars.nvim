local config = require("codewars.config")
local log = require("codewars.logger")
local cache_utils = require("codewars.cache.utils")

---@class cw.Cache.Completed
local completed = {}

local function list_file() return cache_utils.cache_file("completed.json") end
local function details_file() return cache_utils.cache_file("kata_details.json") end

---@return table[], boolean is_stale
function completed.get()
    local raw = cache_utils.read_json(list_file())
    if not raw or not raw.items then return {}, true end
    local age = os.time() - (raw.timestamp or 0)
    -- Its own interval: the problem list can sit for weeks, but kata solved
    -- on the website should show as completed here within a day.
    local stale = age > (config.user.cache.completed_interval or 86400)
    return raw.items, stale
end

---@param data table[]
---@param timestamp integer? keep an existing stamp instead of "now"
function completed.save(data, timestamp)
    cache_utils.write_json(list_file(), {
        timestamp = timestamp or os.time(),
        items = data,
    })
end

---@return table<string, table>
function completed.get_details()
    return cache_utils.read_json(details_file()) or {}
end

---@param details table<string, table>
function completed.save_details(details)
    cache_utils.write_json(details_file(), details)
end

--- Remove both caches. The completed list is the signed-in user's, so it
--- must not outlive their cookie; the kata details are not per-user but
--- are only ever rebuilt from the list, so they go too.
function completed.clear()
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

--- Callers waiting on the refresh in flight, by the account it is for. A
--- list that is replaced, never added to, as the cache's own tables are.
---@type table<string, function[]>
local waiting = {}

--- Refresh the list from Codewars, and hand `cb` the kata and any error.
---
--- One refresh runs at a time per account: a call made while one is in flight
--- sends no request and gets that refresh's result when it ends, an error
--- included. Two replies merged one after the other race -- the newer one
--- can clear a marker that the older, arriving later, still needed.
---@param cb? function
function completed.update(cb)
    local api_utils = require("codewars.api.utils")
    local urls = require("codewars.api.urls")
    local username = config.user.username

    if username == "" then
        -- The username is never configured by hand: it is detected from the
        -- dashboard when the menu opens. Empty here means that detection
        -- failed, so say that instead of implying a missing setting.
        log.warn("Codewars username not detected yet. Open :CW menu to retry, "
            .. "or run :CW cookie if your session expired.")
        if cb then cb({}) end
        return
    end

    if waiting[username] then
        waiting[username] = vim.list_extend(vim.list_slice(waiting[username]), { cb })
        return
    end
    waiting[username] = { cb }

    local all = {}
    local page = 0
    local settled = false

    --- End the refresh: free the slot first, so that whatever a callback does
    --- starts a fresh one, then answer everyone who asked. Whichever way it
    --- ends, this is the one exit.
    local function settle(items, err)
        if settled then return end
        settled = true
        local callers = waiting[username] or {}
        waiting[username] = nil
        for _, caller in ipairs(callers) do
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
        completed.save(all)
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
            completed.save(with_language, raw.timestamp or 0)
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
    completed.save(vim.list_extend({ marked }, items), raw.timestamp or 0)
end

---@class cw.EnrichOpts
---@field names boolean? look a kata up again when its cached details have no name

--- Enrich completed kata with rank/tag details.
---
--- Details cached before names were kept hold a rank and tags and no name.
--- :CW completed has no use for the name and leaves them be; a caller that
--- names kata from them (:CW unfinished) asks with `names`.
---@param items table[]
---@param cb function callback(enriched_items)
---@param opts cw.EnrichOpts?
function completed.enrich(items, cb, opts)
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

    -- Fetch missing details (limit to 50, 5 concurrent)
    local total = math.min(#missing, 50)
    local fetched = 0
    local failed = 0
    local rate_limited = false
    local concurrent = 0
    local max_concurrent = 5
    local idx = 0

    local Spinner = require("codewars.logger.spinner")
    local spinner = Spinner:start(("Fetching kata details (0/%d)"):format(total))

    local function fetch_next()
        while concurrent < max_concurrent and idx < total do
            idx = idx + 1
            concurrent = concurrent + 1
            local slug = missing[idx]
            local kata_api = require("codewars.api.kata")
            kata_api.get(slug, function(res, err)
                concurrent = concurrent - 1
                fetched = fetched + 1

                spinner:update(("Fetching kata details (%d/%d)"):format(fetched, total))

                if not err and res then
                    -- The name too: :CW unfinished lists kata the catalogue
                    -- does not hold, and has nothing else to call them by.
                    details[slug] = { rank = res.rank, tags = res.tags, name = res.name }
                else
                    failed = failed + 1
                    rate_limited = rate_limited or (err and err.rate_limited) or false
                end

                if fetched >= total then
                    if failed == 0 then
                        spinner:success(("Fetched %d kata details"):format(total))
                    else
                        -- Honest count: the ones that failed are still
                        -- missing and will be retried on the next open.
                        spinner:error(("Fetched %d of %d kata details%s"):format(
                            total - failed, total, rate_limited and " (rate limited — try again later)" or ""))
                    end
                    completed.save_details(details)
                    for _, item in ipairs(items) do
                        local s = item.slug or item.id
                        if details[s] then
                            item.rank = details[s].rank
                            item.tags = details[s].tags
                        end
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
