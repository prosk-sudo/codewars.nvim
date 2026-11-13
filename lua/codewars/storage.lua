local config = require("codewars.config")
local log = require("codewars.logger")

---@class cw.Storage
local storage = {}

--- Why `rel` cannot be a path under storage.home, or nil when it can: it must
--- be relative and every component a plain name, so it never leaves home.
---@param rel string
---@return string|nil
local function unsafe(rel)
    if rel:sub(1, 1) == "/" or rel:sub(1, 1) == "~" then
        return "is not relative to storage.home"
    end
    for part in (rel .. "/"):gmatch("([^/]*)/") do
        if part == "" or part == "." or part == ".." or not part:match("^[%w_.-]+$") then
            return ("has an unsafe component %q"):format(part)
        end
    end
    return nil
end

--- Where the solution for `slug` in `lang_slug` lives. `storage.path`, when
--- set, returns the path relative to storage.home; one that errors, returns
--- no path or one that would leave home is reported and the flat default is
--- used, so a broken function can never stop a kata from opening.
---@param slug string
---@param lang_slug string
---@return Path
function storage.solution_file(slug, lang_slug)
    local lang = require("codewars.utils").get_lang(lang_slug)
    assert(lang, "Unsupported language: " .. tostring(lang_slug))
    local rel = ("%s.%s"):format(slug, lang.ft)

    local fn = ((config.user or {}).storage or {}).path
    if type(fn) == "function" then
        local ok, res = pcall(fn, { lang = lang_slug, slug = slug, ext = lang.ft })
        if not ok then
            log.warn(("storage.path failed (%s); using %s"):format(tostring(res), rel))
        elseif type(res) ~= "string" or res == "" then
            log.warn(("storage.path returned no path; using %s"):format(rel))
        else
            local problem = unsafe(res)
            if problem then
                log.warn(("storage.path result %q %s; using %s"):format(res, problem, rel))
            else
                rel = res
            end
        end
    end

    return config.storage.home:joinpath(rel)
end

return storage
