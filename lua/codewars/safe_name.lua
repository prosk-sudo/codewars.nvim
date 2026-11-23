--- Names from outside the plugin that become a path component: kata slug, language, solution file.
--- No requires on purpose: the cache and the UI both load it, and it must work without config.
---@class cw.SafeName
local M = {}

local SLUG = "^[A-Za-z0-9_%-]+$"
local FILE_NAME = "^[A-Za-z0-9_%-]+%.[A-Za-z0-9]+$"

--- True for a non-empty run of ASCII letters, digits, `_` and `-`: one path component, never `..`.
---@param name any
---@return boolean
function M.is_slug(name)
    return type(name) == "string" and name:match(SLUG) ~= nil
end

--- True for `<slug>.<extension>`, the shape of a solution file name.
---@param name any
---@return boolean
function M.is_file_name(name)
    return type(name) == "string" and name:match(FILE_NAME) ~= nil
end

return M
