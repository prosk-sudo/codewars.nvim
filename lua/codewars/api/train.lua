local log = require("codewars.logger")
local urls = require("codewars.api.urls")
local page = require("codewars.api.page")
local api_utils = require("codewars.api.utils")

---@class cw.Api.Train
local train = {}

--- Extract the project ID from the kata train page HTML.
--- The page contains JavaScript with URLs like /projects/{projectId}/{language}/session
---
--- Goes through page.fetch, the shared HTML transport: a 401/429 arrives as a
--- cw.err with the auth / rate_limited flags the caller branches on, a
--- 429 is retried, and a transport failure calls back instead of raising
--- (the raw plenary call this replaced left a mount pending forever when
--- the network was down).
---@param kata_id string The kata ID (not slug)
---@param language string the language being trained -- the train page is
--- per-language, and a kata that lacks Python has no /train/python page at all
---@param cb function callback(project_id?, err?)
function train.get_project_id(kata_id, language, cb)
    local url = ("%s/kata/%s/train/%s"):format(urls.base, kata_id, language)

    page.fetch(url, function(body, perr)
        if perr then
            return cb(nil, page.fetch_err("the train page", perr))
        end

        -- Extract project ID from pattern: /projects/{projectId}/
        local project_id = body:match("/projects/([a-f0-9]+)/")
        if project_id then
            return cb(project_id)
        end

        cb(nil, { msg = ("Could not extract the project ID from the %s train page. Are your cookies valid, and does this kata support %s?"):format(language, language) })
    end)
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
    train.get_project_id(kata_id, language, function(project_id, err)
        if err then
            return cb(nil, err)
        end

        log.debug(("Project ID: %s"):format(project_id))

        train.start_session(project_id, language, function(session, sess_err)
            if sess_err then
                return cb(nil, sess_err)
            end

            -- A 2xx that is not JSON (a login page served with 200, an empty
            -- body) comes back as a string; indexing it raised inside the
            -- callback and the mount never heard back.
            if type(session) ~= "table" then
                return cb(nil, { msg = "Codewars did not return a training session. Run :CW cookie if your session expired." })
            end

            -- Attach project_id to session for later use (finalize, etc.)
            session.projectId = project_id
            cb(session)
        end)
    end)
end

return train
