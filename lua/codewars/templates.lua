--- User-defined starter templates for solution buffers.
---
--- A template is either a string or a function returning one, keyed by
--- language slug under `templates.solution` in the user's config. The text
--- Codewars hands back for a kata (its graded function signature) is passed in
--- as `ctx.starter`; a template containing `{{starter}}` wraps it, one without
--- replaces it outright.
---
--- Resolution advances through the sources in order, skipping any that does not
--- yield a usable string: the configured template, then `ctx.starter`, then "".
--- A template that errors can therefore never stop a kata from opening.
local M = {}

--- Substituted with `ctx.starter`. Named for what the user sees ("starter
--- code"), not the API field it arrives in (`session.setup`).
M.STARTER_TOKEN = "{{starter}}"

--- Languages already warned about this session, so the dropped-signature
--- warning is a nudge on first open rather than noise on every kata.
local warned = {}

--- Test seam: the warning is once-per-session by design, which makes it
--- unobservable across cases without a reset.
function M._reset_warned()
    warned = {}
end

--- The user's template for a language, or nil.
---
--- Read defensively at every level. Most spec files in this repo replace
--- `codewars.config` with a hand-rolled literal that has no `templates` key,
--- and a blind index would turn that into a hard error far from its cause.
---@param lang string
---@return string|function|nil
local function configured_spec(lang)
    local cfg = package.loaded["codewars.config"]
    if cfg == nil then
        local ok, mod = pcall(require, "codewars.config")
        cfg = ok and mod or nil
    end

    local solution = cfg and cfg.user and cfg.user.templates and cfg.user.templates.solution
    return solution and solution[lang] or nil
end

--- File extension for a language, or nil.
---
--- Defensive for the same reason `configured_spec` is: specs in this repo stub
--- `codewars.utils` with a partial table, so neither the module nor the
--- function can be assumed to exist.
---@param lang string
---@return string?
local function extension_for(lang)
    local ok, utils = pcall(require, "codewars.utils")
    if not ok or type(utils) ~= "table" or type(utils.get_lang) ~= "function" then
        return nil
    end
    local found, info = pcall(utils.get_lang, lang)
    return found and type(info) == "table" and info.ft or nil
end

--- Resolve a spec to template text, or nil to advance to the next source.
---@param spec string|function
---@param ctx table
---@return string?
local function evaluate(spec, ctx)
    if type(spec) == "string" then
        return spec ~= "" and spec or nil
    end

    if type(spec) ~= "function" then
        return nil
    end

    local ok, result = pcall(spec, ctx)
    if not ok then
        require("codewars.logger").warn(
            ("Your %s template errored, falling back to the kata's starter code: %s")
                :format(ctx.lang or "?", tostring(result))
        )
        return nil
    end

    -- A function may decline (nil / "") or misbehave (number, table). Both
    -- advance rather than exploding inside the substitution below.
    if type(result) ~= "string" or result == "" then
        return nil
    end
    return result
end

--- Replace every token occurrence with `starter`.
---
--- The replacement MUST be a function: as a string, gsub would treat `%` in the
--- injected code as an escape — `%1` expands to the whole match and `%%`
--- collapses to `%`. That silently mangles real starter code (erlang and prolog
--- use `%` for comments). A function's return is used verbatim, and gsub never
--- rescans it, so a `{{starter}}` inside the injected text is left alone.
---@param template string
---@param starter string
---@return string
local function substitute(template, starter)
    -- Braces are not Lua pattern metacharacters, so the token is literal.
    return (template:gsub(M.STARTER_TOKEN, function()
        return starter
    end))
end

---@param lang string
---@param ctx table starter code plus kata metadata; see cw.TemplateCtx
local function warn_dropped_signature(lang, ctx)
    if warned[lang] then
        return
    end
    warned[lang] = true
    require("codewars.logger").warn(
        ("Your %s template has no %s — this kata's signature was dropped. "
            .. "You probably want %s where it should go.")
            :format(lang, M.STARTER_TOKEN, M.STARTER_TOKEN)
    )
end

--- Starter text for a solution buffer.
---@param lang string language slug
---@param ctx table `{ starter = string, lang?, ext?, slug?, name?, rank?, tags? }`
---@return string
function M.render(lang, ctx)
    ctx = ctx or {}
    local starter = ctx.starter or ""

    -- A new table rather than a mutated argument, and callers win over the
    -- defaults so a kata can pass richer metadata than we can derive here.
    local resolved = vim.tbl_extend("keep", ctx, {
        lang = lang,
        ext = extension_for(lang),
        starter = starter,
    })

    local template = evaluate(configured_spec(lang), resolved)
    if not template then
        return starter
    end

    if not template:find(M.STARTER_TOKEN, 1, true) then
        if starter ~= "" then
            warn_dropped_signature(lang, resolved)
        end
        return template
    end

    return substitute(template, starter)
end

return M
