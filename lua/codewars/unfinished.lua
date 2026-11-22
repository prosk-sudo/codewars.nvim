--- Kata you started and never submitted.
---
--- A solution file in storage.home is unfinished when its kata is not completed
--- in that language and the file no longer holds the starter it was seeded
--- with, so a kata you only looked at is not listed.
---
--- The starter is not kept (Codewars sends it with each session and the cached
--- copy expires), so a fingerprint of it is recorded in .seeded.json whenever a
--- solution is seeded. A file seeded before that record existed cannot be
--- checked: it is listed, marked as such, until the kata is opened again.
local config = require("codewars.config")
local cache_utils = require("codewars.cache.utils")

local M = {}

local RECORD = ".seeded.json"

--- A fingerprint from the current algorithm starts with this; bare digests are
--- the old kind.
local PRINT_V2 = "v2:"

--- The old fingerprint (all whitespace removed). It confuses `"hello world"`
--- with `"helloworld"`, so nothing writes it; it stays to compare records
--- already on disk.
---@param text string
---@return string
local function legacy_fingerprint(text)
    return vim.fn.sha256((text:gsub("%s+", "")))
end

--- Ignores indentation, trailing spaces, blank lines and the final newline, so
--- re-indenting an untouched starter does not make it look started. Each line
--- is kept exactly between its first and last non-blank character, so a space
--- inside a string or between tokens counts. (Re-indenting inside a multi-line
--- string is deliberately not told apart from re-indenting.)
---@param text string
---@return string
function M.fingerprint(text)
    local lines = {}
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        line = vim.trim(line)
        if line ~= "" then lines[#lines + 1] = line end
    end
    return PRINT_V2 .. vim.fn.sha256(table.concat(lines, "\n"))
end

--- Whether `text` is one of the starters `prints` stand for, each print
--- compared by the algorithm that made it.
---@param prints string[]
---@param text string
---@return boolean
local function holds_starter(prints, text)
    local current, legacy = M.fingerprint(text), nil
    for _, known in ipairs(prints) do
        if type(known) == "string" then
            if vim.startswith(known, PRINT_V2) then
                if known == current then return true end
            else
                legacy = legacy or legacy_fingerprint(text)
                if known == legacy then return true end
            end
        end
    end
    return false
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
        -- Early records were a bare list of fingerprints.
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

--- A file was just written with a freshly seeded starter. REPLACES the
--- starters on record, since the file that held them is gone; the name stays.
---@param file_name string
---@param text string
---@param info cw.KataInfo?
function M.seeded(file_name, text, info)
    local data = load()
    local old = data[file_name] or {}
    data[file_name] = with_info({ prints = { M.fingerprint(text) }, name = old.name, rank_id = old.rank_id }, info)
    save(data)
end

--- :CW reset put a fresh starter in the buffer. ADDS it to the starters on
--- record (`seeded` replaces them): the file keeps its old content until the
--- buffer is saved, and an untouched old starter must not look like work.
--- A starter already on record is not added twice.
---@param file_name string
---@param text string
---@param info cw.KataInfo?
function M.reseeded(file_name, text, info)
    local data = load()
    local old = data[file_name] or { prints = {} }
    local fresh = M.fingerprint(text)
    local prints = old.prints
    if not vim.tbl_contains(prints, fresh) then
        prints = vim.list_extend(vim.list_slice(prints), { fresh })
    end
    data[file_name] = with_info({ prints = prints, name = old.name, rank_id = old.rank_id }, info)
    save(data)
end

--- A kata opened its existing file. With nothing on record, today's starter is
--- the best guess: a file that matches it is untouched, and one that does not
--- is listed, which is the safe way to be wrong.
---@param file_name string
---@param starter string|fun(): string the starter, or how to make it; only made when nothing is on record
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
    if not (rec and holds_starter(rec.prints, before)) then return end
    if holds_starter(rec.prints, after) then return end
    data[file_name] = with_info({
        prints = vim.list_extend(vim.list_slice(rec.prints, 1, #rec.prints), { M.fingerprint(after) }),
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

--- Whether a directory entry is a solution file, and its stat: a regular file
--- or a symlink to one (a kata opens a solution through a link too). A broken
--- link or a link to a directory is not. The stat follows the link, so its
--- time is when the target was last changed.
---@param path string
---@param kind string as vim.fs.dir reports it ("file", "link", "directory"...)
---@return boolean is_solution
---@return table? stat
local function solution_file(path, kind)
    if kind ~= "file" and kind ~= "link" then return false end
    local stat = vim.loop.fs_stat(path)
    if kind == "link" then return stat ~= nil and stat.type == "file", stat end
    return true, stat
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
---@field mtime_nsec integer the nanoseconds past `mtime`; saves in the same second still sort
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
        local path = home .. "/" .. name
        local is_solution, stat
        if lang and not done[key .. "|" .. lang] then is_solution, stat = solution_file(path, kind) end
        if is_solution then
            local rec = record[name]
            local text = rec and read(path)
            if not (text and holds_starter(rec.prints, text)) then
                entries[#entries + 1] = {
                    key = key,
                    lang = lang,
                    file = name,
                    mtime = stat and stat.mtime.sec or 0,
                    mtime_nsec = stat and stat.mtime.nsec or 0,
                    checked = rec ~= nil,
                    name = rec and rec.name,
                    rank_id = rec and rec.rank_id,
                }
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        if a.mtime_nsec ~= b.mtime_nsec then return a.mtime_nsec > b.mtime_nsec end
        return a.file < b.file
    end)
    return entries
end

return M
