local config = require("codewars.config")
local lvls = vim.log.levels

---@class cw.Logger
local logger = {}

---@param msg any
---@param lvl? integer
function logger.log(msg, lvl)
    if not config.user.logging then
        return
    end

    local title = config.name
    lvl = lvl or lvls.INFO
    msg = type(msg) == "string" and msg or vim.inspect(msg)

    if lvl == lvls.DEBUG then
        msg = debug.traceback(msg .. "\n")
    end

    vim.schedule(function()
        vim.notify(msg, lvl, { title = title })
    end)
end

---@param msg any
function logger.info(msg)
    logger.log(msg)
end

---@param msg any
function logger.warn(msg)
    logger.log(msg, lvls.WARN)
end

---@param msg any
function logger.error(msg)
    logger.log(msg, lvls.ERROR)
    logger.debug(msg)
end

---@param err cw.err
function logger.err(err)
    if not err then
        return logger.error("error")
    end
    logger.log(err.msg or "", err.lvl or lvls.ERROR)
end

---@param msg any
function logger.debug(msg)
    if not config.debug then
        return msg
    end
    logger.log(msg, lvls.DEBUG)
    return msg
end

return logger
