local utils = require("codewars.api.utils")
local urls = require("codewars.api.urls")

---@class cw.Api.Kata
local kata = {}

---@param slug string
---@param cb? function
---@return table?, cw.err?
function kata.get(slug, cb)
    local endpoint = urls.kata:format(slug)

    if cb then
        utils.get(endpoint, { callback = cb })
    else
        return utils.get(endpoint)
    end
end

return kata
