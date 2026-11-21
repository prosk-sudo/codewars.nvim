--- Names that come from outside the plugin and end up as a component of a
--- path: a kata slug, a language slug, a solution file name. They arrive in a
--- Codewars reply, in what the user typed, or in a file name picked from a
--- list, so none of them can be trusted not to carry a separator or `..`
--- out of the directory they are joined onto.
---
--- One rule decides, so the places that build such a path cannot drift apart.
--- Free of requires on purpose: the cache and the UI both load it, and it must
--- work without config.
---@class cw.SafeName
local M = {}

local SLUG = "^[A-Za-z0-9_%-]+$"
local FILE_NAME = "^[A-Za-z0-9_%-]+%.[A-Za-z0-9]+$"

--- True for a non-empty run of ASCII letters, digits, `_` and `-`: a name that
--- can be one path component, and cannot be anything else (no separator, no
--- dot, so no `..`; no whitespace or control character either).
---@param name any
---@return boolean
function M.is_slug(name)
    return type(name) == "string" and name:match(SLUG) ~= nil
end

--- True for `<slug>.<extension>`, the one shape of a solution file name: a
--- plain file name, one dot, nothing that could name a directory.
---@param name any
---@return boolean
function M.is_file_name(name)
    return type(name) == "string" and name:match(FILE_NAME) ~= nil
end

return M
