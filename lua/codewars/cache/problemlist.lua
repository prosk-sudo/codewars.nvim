local config = require("codewars.config")
local cache_utils = require("codewars.cache.utils")

---@class cw.Cache.Problemlist
local problemlist = {}

local function cache_file()
    return cache_utils.cache_file("problemlist.json")
end

---@return table? { items: table[], timestamp: integer, lang: string }
function problemlist.get()
    local data = cache_utils.read_json(cache_file())
    if not data then return nil end

    local age = os.time() - (data.timestamp or 0)
    local interval = (config.user.cache or {}).update_interval or (7 * 24 * 60 * 60)
    if age > interval then return nil end

    return data.items
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
    local max_concurrent = 10
    local rank_idx = 0
    local aborted = false

    local function finish()
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
                        return finish()
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
                            fetch_batch()
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
