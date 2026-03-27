local P = require("plenary.path")
local config = require("codewars.config")
local log = require("codewars.logger")

local M = {}

---@param name string filename within the cache directory
---@return Path
function M.cache_file(name)
    if config.storage.cache then
        return config.storage.cache:joinpath(name)
    end
    local dir = P:new(vim.fn.stdpath("cache") .. "/codewars")
    dir:mkdir({ parents = true })
    return dir:joinpath(name)
end

---@param path Path
---@return table?
function M.read_json(path)
    local ok, data = pcall(function()
        return vim.json.decode(path:read())
    end)
    return ok and data or nil
end

---@param path Path
---@param data table
function M.write_json(path, data)
    local ok, err = pcall(function()
        path:write(vim.json.encode(data), "w")
    end)
    if not ok then
        log.error("Failed to write cache: " .. tostring(err))
    end
end

return M
