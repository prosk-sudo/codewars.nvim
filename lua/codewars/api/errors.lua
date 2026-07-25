--- Shared recognisers for Codewars rejections.
---
--- These match on wording because that is all the responses give us: a kata
--- save returns a re-rendered form and a kumite convert returns JSON, so there
--- is no shared status or code to key off. Keeping the match in one place
--- means the two workspaces cannot drift apart on what counts as a collision.
---@class cw.Api.Errors
local M = {}

--- True when Codewars refused because the name is already in use.
---@param err cw.err?
---@return boolean
function M.is_name_taken(err)
    return err ~= nil and tostring(err.msg or ""):lower():find("already taken", 1, true) ~= nil
end

return M
