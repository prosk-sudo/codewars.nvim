local config = require("codewars.config")
local cache_utils = require("codewars.cache.utils")

---@class cw.Cache.Problemlist
local problemlist = {}

local function cache_file()
    return cache_utils.cache_file("problemlist.json")
end

local DEFAULT_INTERVAL = 30 * 24 * 60 * 60

---@return integer seconds after which the list counts as stale
local function interval()
    return (config.user.cache or {}).update_interval or DEFAULT_INTERVAL
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

local refreshing = false

--- Rebuild the list in the background when it is stale. Returns true when a
--- refresh was started (or is already running). Silent otherwise.
---@return boolean
function problemlist.refresh_if_stale()
    local items, stale, age = problemlist.get()
    if not items or not stale then return false end
    if refreshing then return true end
    refreshing = true
    local days = math.floor((age or 0) / 86400)
    require("codewars.logger").info(("Problem list is %d days old — refreshing in the background."):format(days))
    problemlist.update({}, function()
        refreshing = false
    end)
    return true
end

--- Fetch fresh problem list by querying each rank separately (all languages).
--- Codewars caps search results at ~48 pages per query, so we fetch per-rank
--- to get full coverage, without a language filter so we get all kata.
---@param opts? table
---@param cb function callback(items[])
function problemlist.update(opts, cb)
    opts = opts or {}
    local max_pages_per_rank = opts.max_pages or 100
    local search = require("codewars.api.search")

    local Spinner = require("codewars.logger.spinner")
    local spinner = Spinner:start("Updating problem list cache")

    local all_results = {}
    local ranks = { -8, -7, -6, -5, -4, -3, -2, -1 }
    local rank_labels = { [-8]="8 kyu", [-7]="7 kyu", [-6]="6 kyu", [-5]="5 kyu", [-4]="4 kyu", [-3]="3 kyu", [-2]="2 kyu", [-1]="1 kyu" }
    -- Codewars publishes no rate limit, and a full build is ~8 ranks x up to
    -- 100 pages. Ten-wide with no pause between batches reliably earned a
    -- 429 partway through. Fewer in flight, with a gap between batches, is
    -- slower but actually finishes.
    local max_concurrent = 4
    local batch_gap_ms = 200
    local rank_idx = 0
    local aborted = false

    ---@param partial boolean? true when we stopped early and must not
    --- pretend the cache is complete
    local function finish(partial)
        -- Deduplicate
        local seen = {}
        local unique = {}
        for _, item in ipairs(all_results) do
            local slug = item.slug or item.id
            if not seen[slug] then
                seen[slug] = true
                table.insert(unique, item)
            end
        end

        -- Every page parsing as empty is not "Codewars has no kata": it is
        -- search-markup drift or an interstitial page that returned 200.
        -- fetch_page reports parse-empty as an ordinary end of rank, so this
        -- is the one place that can tell the two apart.
        if not partial and #unique == 0 then
            spinner:error("No kata found on any search page — the site markup may have changed; cache left as is.")
            partial = true
        end

        if partial then
            -- Deliberately not written: a short list stamped with `now` would
            -- look fresh for the whole cache interval, quietly hiding the
            -- kata we never fetched. Leaving it unwritten means the next run
            -- retries instead. The flag tells the caller not to report
            -- success on top of the failure the spinner already showed.
            cb(unique, true)
            return
        end

        cache_utils.write_json(cache_file(), {
            items = unique,
            timestamp = os.time(),
        })

        spinner:success(("Cached %d kata"):format(#unique))
        cb(unique)
    end

    local function fetch_rank()
        rank_idx = rank_idx + 1
        if aborted or rank_idx > #ranks then
            return finish()
        end

        local rank = ranks[rank_idx]
        local label = rank_labels[rank] or tostring(rank)
        local current_page = 0
        local rank_done = false

        local fetch_opts = {
            language = "", -- no language filter, fetch all kata
            rank = { rank },
            order = "popularity+desc",
            -- Once one page has given up, the rest of the batch must not
            -- keep retrying into the same limiter.
            cancelled = function() return aborted end,
        }

        local function fetch_batch()
            if aborted or rank_done or current_page >= max_pages_per_rank then
                return fetch_rank()
            end

            local batch_start = current_page
            local batch_end = math.min(current_page + max_concurrent - 1, max_pages_per_rank - 1)
            local batch_done = 0
            local batch_size = batch_end - batch_start + 1
            local batch_empty = 0
            local batch_has_more = false

            for page = batch_start, batch_end do
                search.fetch_page(fetch_opts, page, function(results, has_more, err)
                    if aborted then return end

                    if err and err.auth then
                        aborted = true
                        local log = require("codewars.logger")
                        log.error(err.msg)
                        spinner:error("Fetch aborted: authentication error")
                        -- Partial, same as the rate-limit abort: writing here
                        -- would stamp a truncated list as fresh and hide every
                        -- kata the aborted run never reached.
                        return finish(true)
                    end

                    if err and err.rate_limited then
                        -- fetch_page already backed off and retried; if it is
                        -- still refusing, stop rather than grinding through
                        -- the remaining ranks earning more 429s.
                        aborted = true
                        spinner:error(("Rate limited by Codewars after %d kata — wait a minute and run :CW cache update again"):format(#all_results))
                        return finish(true)
                    end

                    if err then
                        -- Any other failure (5xx after retries, curl could
                        -- not connect, unexpected status). Treating it as an
                        -- empty page would end the rank early and write the
                        -- truncated list as fresh — the same silent hole the
                        -- 429 path above exists to prevent.
                        aborted = true
                        spinner:error(("Fetch failed after %d kata: %s"):format(#all_results, err.msg or "unknown error"))
                        return finish(true)
                    end

                    batch_done = batch_done + 1

                    if results and #results > 0 then
                        vim.list_extend(all_results, results)
                    else
                        batch_empty = batch_empty + 1
                    end

                    if has_more then
                        batch_has_more = true
                    end

                    spinner:update(("Fetching kata (%d found, %s)"):format(#all_results, label))

                    if batch_done >= batch_size then
                        current_page = batch_end + 1

                        if batch_empty >= batch_size or not batch_has_more then
                            rank_done = true
                            fetch_rank()
                        else
                            -- Breathe between batches instead of firing the
                            -- next four the instant these land.
                            vim.defer_fn(fetch_batch, batch_gap_ms)
                        end
                    end
                end)
            end
        end

        fetch_batch()
    end

    fetch_rank()
end

function problemlist.delete()
    local f = cache_file()
    if f:exists() then f:rm() end
end

return problemlist
