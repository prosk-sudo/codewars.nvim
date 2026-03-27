local curl = require("plenary.curl")
local log = require("codewars.logger")
local urls = require("codewars.api.urls")
local headers_mod = require("codewars.api.headers")
local api_utils = require("codewars.api.utils")

---@class cw.Api.Train
local train = {}

--- Extract the project ID from the kata train page HTML.
--- The page contains JavaScript with URLs like /projects/{projectId}/{language}/session
---@param kata_id string The kata ID (not slug)
---@param cb function callback(project_id?, err?)
function train.get_project_id(kata_id, cb)
    local url = ("%s/kata/%s/train/python"):format(urls.base, kata_id)
    local hdrs = headers_mod.get()

    curl.get(url, {
        headers = hdrs,
        compressed = false,
        callback = vim.schedule_wrap(function(out)
            if out.exit ~= 0 or out.status >= 300 then
                return cb(nil, {
                    msg = ("Failed to fetch train page (HTTP %d). Are your cookies valid?"):format(out.status or 0),
                    status = out.status,
                })
            end

            local body = out.body or ""

            -- Extract project ID from pattern: /projects/{projectId}/
            local project_id = body:match("/projects/([a-f0-9]+)/")
            if project_id then
                return cb(project_id)
            end

            cb(nil, { msg = "Could not extract project ID from train page. Are your cookies valid?" })
        end),
    })
end

--- Start a training session.
--- POST /kata/projects/{projectId}/{language}/session
---@param project_id string
---@param language string
---@param cb function callback(session?, err?)
function train.start_session(project_id, language, cb)
    local endpoint = ("/kata/projects/%s/%s/session"):format(project_id, language)

    api_utils.post(endpoint, {
        body = {},
        callback = cb,
    })
end

--- Full training flow: get project ID from HTML, then start session.
---@param kata_id string  The kata ID (from the kata record)
---@param language string
---@param cb function callback(session?, err?)
function train.start(kata_id, language, cb)
    train.get_project_id(kata_id, function(project_id, err)
        if err then
            return cb(nil, err)
        end

        log.debug(("Project ID: %s"):format(project_id))

        train.start_session(project_id, language, function(session, sess_err)
            if sess_err then
                return cb(nil, sess_err)
            end

            -- Attach project_id to session for later use (finalize, etc.)
            session.projectId = project_id
            cb(session)
        end)
    end)
end

return train
