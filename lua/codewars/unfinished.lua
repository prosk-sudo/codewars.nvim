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

---@return table<string, string[]> solution file name -> fingerprints that count as untouched
local function load()
    local data = cache_utils.read_json(record_path())
    return type(data) == "table" and data or {}
end

local function save(data)
    cache_utils.write_json(record_path(), data)
end

--- `file_name` now holds a freshly seeded starter: a new kata, or :CW reset.
--- Whatever was on record goes, since that starter is gone.
---@param file_name string
---@param text string
function M.seeded(file_name, text)
    local data = load()
    data[file_name] = { M.fingerprint(text) }
    save(data)
end

--- An existing file opened with nothing on record. The starter it would be
--- seeded with today is the best record there is: a file that still matches it
--- is untouched, and one that does not is listed -- the safe way to be wrong.
---@param file_name string
---@param starter string|fun(): string the starter, or how to make it -- only made when nothing is on record
function M.seeded_if_unknown(file_name, starter)
    local data = load()
    if data[file_name] then return end
    local text = type(starter) == "function" and starter() or starter
    data[file_name] = { M.fingerprint(text) }
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
    local prints = data[file_name]
    if not (prints and vim.tbl_contains(prints, M.fingerprint(before))) then return end
    local print_after = M.fingerprint(after)
    if vim.tbl_contains(prints, print_after) then return end
    data[file_name] = vim.list_extend(vim.list_slice(prints, 1, #prints), { print_after })
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
            local prints = record[name]
            local text = prints and read(path)
            if not (text and vim.tbl_contains(prints, M.fingerprint(text))) then
                local stat = vim.loop.fs_stat(path)
                entries[#entries + 1] = {
                    key = key,
                    lang = lang,
                    file = name,
                    mtime = stat and stat.mtime.sec or 0,
                    checked = prints ~= nil,
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
