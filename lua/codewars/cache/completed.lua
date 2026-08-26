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
    local stale = age > (config.user.cache.update_interval or 86400)
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

    local all = {}
    local page = 0

    local function fetch_page()
        local endpoint = urls.completed:format(username, page)
        api_utils.get(endpoint, {
            callback = function(res, err)
                if err then
                    -- Not saved: writing the pages fetched so far would
                    -- stamp a partial list as fresh and overwrite a valid
                    -- older cache, so kata completed on later pages would
                    -- show as unsolved until the cache interval expired.
                    -- Hand back whatever is on disk and let the next open
                    -- retry.
                    log.err(err)
                    if cb then cb((completed.get()), err) end
                    return
                end

                if not (type(res) == "table" and type(res.data) == "table") then
                    -- A 2xx without `data` is not "no completed kata": it is
                    -- a reply we do not understand (interstitial, drift).
                    -- Saving `all` here overwrote a valid cache with a
                    -- fresh-stamped empty or partial list.
                    local bad = { msg = "Unexpected reply from the completed-kata API; keeping the cached list." }
                    log.err(bad)
                    if cb then cb((completed.get()), bad) end
                    return
                end

                vim.list_extend(all, res.data)
                if res.totalPages and page < res.totalPages - 1 then
                    page = page + 1
                    fetch_page()
                else
                    -- A kata marked complete locally while this refresh was
                    -- in flight is not in the fetched pages yet; keep it
                    -- rather than un-completing it until the next refresh.
                    local fetched = {}
                    for _, item in ipairs(all) do fetched[item.id] = true end
                    for _, item in ipairs((completed.get())) do
                        if item.local_mark and not fetched[item.id] then
                            table.insert(all, 1, item)
                        end
                    end
                    completed.save(all)
                    log.info(("Fetched %d completed kata"):format(#all))
                    if cb then cb(all) end
                end
            end,
        })
    end

    fetch_page()
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
    -- Check if already present
    for _, item in ipairs(items) do
        if item.id == kata_id then return end
    end
    table.insert(items, 1, {
        id = kata_id,
        slug = slug or kata_id,
        completedLanguages = lang and { lang } or {},
        completedAt = os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
        local_mark = true,
    })
    completed.save(items, raw.timestamp or 0)
end

--- Enrich completed kata with rank/tag details.
---@param items table[]
---@param cb function callback(enriched_items)
function completed.enrich(items, cb)
    local details = completed.get_details()
    local missing = {}

    for _, item in ipairs(items) do
        local slug = item.slug or item.id
        if not slug then goto continue end
        if details[slug] then
            item.rank = details[slug].rank
            item.tags = details[slug].tags
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
                    details[slug] = { rank = res.rank, tags = res.tags }
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
