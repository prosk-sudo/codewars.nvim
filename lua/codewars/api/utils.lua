local curl = require("plenary.curl")
local log = require("codewars.logger")
local headers = require("codewars.api.headers")
local urls = require("codewars.api.urls")

---@class cw.err
---@field code? integer
---@field status? integer
---@field msg string
---@field lvl? integer

---@class cw.Api.Utils
local utils = {}

---@param endpoint string
---@param opts? table
function utils.post(endpoint, opts)
    local options = vim.tbl_deep_extend("force", {
        endpoint = endpoint,
    }, opts or {})

    return utils.curl("post", options)
end

---@param endpoint string
---@param opts? table
function utils.get(endpoint, opts)
    local options = vim.tbl_deep_extend("force", {
        endpoint = endpoint,
    }, opts or {})

    return utils.curl("get", options)
end

---@private
---@param method string
---@param params table
function utils.curl(method, params)
    local params_cpy = vim.deepcopy(params)

    params = vim.tbl_deep_extend("force", {
        headers = headers.get(),
        compressed = false,
        retry = 3,
        endpoint = "",
    }, params or {})

    local url = urls.base .. params.endpoint

    if type(params.body) == "table" then
        params.body = vim.json.encode(params.body)
    end

    local tries = params.retry
    local function should_retry(err)
        return err and err.status and err.status >= 500 and tries > 0
    end

    if params.callback then
        local cb = vim.schedule_wrap(params.callback)
        params.callback = function(out, _)
            local res, err = utils.handle_res(out)

            if should_retry(err) then
                log.debug("retry " .. tries)
                params_cpy.retry = tries - 1
                utils.curl(method, params_cpy)
            else
                cb(res, err)
            end
        end

        curl[method](url, params)
    else
        local out = curl[method](url, params)
        local res, err = utils.handle_res(out)

        if should_retry(err) then
            log.debug("retry " .. tries)
            params_cpy.retry = tries - 1
            return utils.curl(method, params_cpy)
        else
            return res, err
        end
    end
end

---@private
---@return table?, cw.err?
function utils.handle_res(out)
    local res, err

    log.debug(out)

    if not out then
        return nil, { msg = "No response received" }
    end

    if out.exit ~= 0 then
        err = {
            code = out.exit,
            msg = "curl failed",
        }
    elseif out.status == 401 or out.status == 403 then
        err = {
            code = 0,
            status = out.status,
            msg = "Session expired or invalid. Run :CW cookie to re-authenticate.",
            auth = true,
        }
    elseif out.status >= 300 then
        local ok, msg = pcall(function()
            local dec = vim.json.decode(out.body)
            if dec.reason then
                return dec.reason
            end
            if dec.error then
                return dec.error
            end
            return "unknown error"
        end)

        res = out.body
        err = {
            code = 0,
            status = out.status,
            msg = "http error " .. out.status .. (ok and ("\n\n" .. msg) or ""),
        }
    else
        local ok, decoded = pcall(vim.json.decode, out.body)
        if ok then
            res = decoded
        else
            res = out.body
        end
    end

    return res, err
end

return utils
