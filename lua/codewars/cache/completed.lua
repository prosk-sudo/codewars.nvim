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
function completed.save(data)
    cache_utils.write_json(list_file(), {
        timestamp = os.time(),
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

---@param cb? function
function completed.update(cb)
    local api_utils = require("codewars.api.utils")
    local urls = require("codewars.api.urls")
    local username = config.user.username

    if username == "" then
        log.warn("Username not configured")
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
                    log.err(err)
                    completed.save(all)
                    if cb then cb(all) end
                    return
                end

                if res and res.data then
                    vim.list_extend(all, res.data)
                    if res.totalPages and page < res.totalPages - 1 then
                        page = page + 1
                        fetch_page()
                    else
                        completed.save(all)
                        log.info(("Fetched %d completed kata"):format(#all))
                        if cb then cb(all) end
                    end
                else
                    completed.save(all)
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
    local items = completed.get()
    -- Check if already present
    for _, item in ipairs(items) do
        if item.id == kata_id then return end
    end
    table.insert(items, 1, {
        id = kata_id,
        slug = slug or kata_id,
        completedLanguages = lang and { lang } or {},
        completedAt = os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
    })
    completed.save(items)
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
                end

                if fetched >= total then
                    spinner:success(("Fetched %d kata details"):format(total))
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
