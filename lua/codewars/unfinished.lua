--- Kata you started and never submitted.
---
--- Every kata you open leaves a solution file in storage.home. One is
--- unfinished when its kata is not completed in that language and the file no
--- longer holds the starter it was seeded with: a kata you only looked at is
--- not one you are in the middle of.
---
--- The starter itself is not kept -- Codewars sends it with each training
--- session, and the cached copy of that expires -- so a fingerprint of it is
--- recorded next to the solutions, in .seeded.json, whenever one is written.
--- A file seeded before that record existed cannot be checked. It is listed,
--- marked as such, until the kata is opened again.
local config = require("codewars.config")
local cache_utils = require("codewars.cache.utils")

local M = {}

local RECORD = ".seeded.json"

--- Whitespace does not count: re-indenting a starter, or the newline an
--- editor adds at the end of a file, is not work on the kata.
---@param text string
---@return string
function M.fingerprint(text)
    return vim.fn.sha256((text:gsub("%s+", "")))
end

local function record_path()
    return config.storage.home:joinpath(RECORD)
end

---@class cw.SeededRecord
---@field prints string[] fingerprints of the starters that count as untouched
---@field name string? the kata's name, as it was last opened with
---@field rank_id integer? its rank, likewise; the catalogue does not hold every kata

---@class cw.KataInfo
---@field name string?
---@field rank_id integer?

---@return table<string, cw.SeededRecord> by solution file name
local function load()
    local data = cache_utils.read_json(record_path())
    if type(data) ~= "table" then return {} end
    for file_name, rec in pairs(data) do
        -- The first records held only the fingerprints, as a bare list.
        if type(rec) == "table" and rec.prints == nil then
            data[file_name] = { prints = rec }
        end
    end
    return data
end

local function save(data)
    cache_utils.write_json(record_path(), data)
end

--- `rec` with `info`'s name and rank, keeping its own where `info` has none.
---@param rec cw.SeededRecord
---@param info cw.KataInfo?
---@return cw.SeededRecord
local function with_info(rec, info)
    info = info or {}
    return {
        prints = rec.prints,
        name = info.name or rec.name,
        rank_id = info.rank_id or rec.rank_id,
    }
end

--- `file_name` now holds a freshly seeded starter: a new kata, or :CW reset.
--- The starters on record go, since that one is gone; the name stays.
---@param file_name string
---@param text string
---@param info cw.KataInfo?
function M.seeded(file_name, text, info)
    local data = load()
    local old = data[file_name] or {}
    data[file_name] = with_info({ prints = { M.fingerprint(text) }, name = old.name, rank_id = old.rank_id }, info)
    save(data)
end

--- A kata opened its existing file. With nothing on record, the starter it
--- would be seeded with today is the best record there is: a file that still
--- matches it is untouched, and one that does not is listed -- the safe way to
--- be wrong.
---@param file_name string
---@param starter string|fun(): string the starter, or how to make it -- only made when nothing is on record
---@param info cw.KataInfo?
function M.opened(file_name, starter, info)
    local data = load()
    local rec = data[file_name]
    if rec and not info then return end
    if not rec then
        local text = type(starter) == "function" and starter() or starter
        rec = { prints = { M.fingerprint(text) } }
    end
    data[file_name] = with_info(rec, info)
    save(data)
end

--- A template toggle rewrote the buffer from `before` to `after`. When
--- `before` was an untouched starter so is `after`, and the file may yet be
--- saved either way round, so both stay on record.
---@param file_name string
---@param before string
---@param after string
function M.retemplated(file_name, before, after)
    local data = load()
    local rec = data[file_name]
    if not (rec and vim.tbl_contains(rec.prints, M.fingerprint(before))) then return end
    local print_after = M.fingerprint(after)
    if vim.tbl_contains(rec.prints, print_after) then return end
    data[file_name] = with_info({
        prints = vim.list_extend(vim.list_slice(rec.prints, 1, #rec.prints), { print_after }),
        name = rec.name,
        rank_id = rec.rank_id,
    })
    save(data)
end

--- Slug and id, per language, of every completed kata.
---@param completed table[]
---@return table<string, true>
local function completed_index(completed)
    local done = {}
    for _, item in ipairs(completed) do
        for _, lang in ipairs(item.completedLanguages or {}) do
            if item.slug then done[item.slug .. "|" .. lang] = true end
            if item.id then done[item.id .. "|" .. lang] = true end
        end
    end
    return done
end

---@param path string
---@return string?
local function read(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and table.concat(lines, "\n") or nil
end

---@class cw.UnfinishedEntry
---@field key string the kata's slug, or its id for files named that way
---@field lang string language slug
---@field file string file name in storage.home
---@field mtime integer last changed, in seconds since the epoch
---@field checked boolean false when nothing was on record to check it against
---@field name string? the kata's name as it was last opened with, when on record
---@field rank_id integer? its rank, likewise

--- Unfinished kata, most recently changed first.
---@param completed table[] completed kata, as cache.completed holds them
---@return cw.UnfinishedEntry[]
function M.list(completed)
    local home = config.storage.home:absolute()
    if not vim.loop.fs_stat(home) then return {} end

    local lang_of = {}
    for _, l in ipairs(config.langs) do lang_of[l.ft] = l.slug end
    local done = completed_index(completed)
    local record = load()

    local entries = {}
    for name, kind in vim.fs.dir(home) do
        local key, ext = name:match("^(.+)%.([^.]+)$")
        local lang = ext and lang_of[ext]
        if kind == "file" and lang and not done[key .. "|" .. lang] then
            local path = home .. "/" .. name
            local rec = record[name]
            local text = rec and read(path)
            if not (text and vim.tbl_contains(rec.prints, M.fingerprint(text))) then
                local stat = vim.loop.fs_stat(path)
                entries[#entries + 1] = {
                    key = key,
                    lang = lang,
                    file = name,
                    mtime = stat and stat.mtime.sec or 0,
                    checked = rec ~= nil,
                    name = rec and rec.name,
                    rank_id = rec and rec.rank_id,
                }
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        return a.file < b.file
    end)
    return entries
end

return M
