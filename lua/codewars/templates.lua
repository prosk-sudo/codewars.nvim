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

--- Marker file whose presence means "off", or nil before config.setup() has
--- built the storage paths. Presence rather than contents: there are two
--- states, and a file that exists is harder to misparse than one that holds
--- a word.
---
--- Deliberately not cache.utils.cache_file, which binds `codewars.config` at
--- module load — this file reads it live because most specs swap it — and
--- whose fallback branch creates a directory, which a read-only predicate has
--- no business doing.
---@return Path?
local function switch_path()
    local cfg = package.loaded["codewars.config"]
    local cache = cfg and cfg.storage and cfg.storage.cache
    return cache and cache.joinpath and cache:joinpath("templates_off") or nil
end

--- Whether templates are currently applied. On unless explicitly turned off.
---
--- Read from disk each time rather than cached: this is reached once or twice
--- per kata open or `:CW template`, never in a loop, and a cache would need a
--- tri-state and a "do not cache before setup()" carve-out to be correct.
---@return boolean
function M.is_enabled()
    local path = switch_path()
    if not path then
        return true
    end

    local ok, exists = pcall(function()
        return path:exists()
    end)
    return not (ok and exists)
end

--- Turn templates on or off for every language, persisted across restarts.
---@param on boolean
function M.set_enabled(on)
    local path = switch_path()
    if not path then
        return
    end

    pcall(function()
        if on then
            if path:exists() then
                path:rm()
            end
        else
            path:write("", "w")
        end
    end)
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

--- Indentation to carry onto the starter's continuation lines: the whitespace
--- between the start of the token's line and the token itself.
---
--- Returns "" when anything else precedes the token on that line. A mid-line
--- token (`x = {{starter}}`) has no indent that would sensibly apply to the
--- lines below it, so it splices verbatim as before.
---@param template string
---@param token_start integer index of the token's first character
---@return string
local function indent_before(template, token_start)
    local before = template:sub(1, token_start - 1)
    local prefix = before:sub(before:find("[^\n]*$"))
    return prefix:match("^[ \t]*$") and prefix or ""
end

--- Apply `fn` to every line after the first.
---
--- The first line is left alone by both callers: it sits behind the template's
--- own indentation already, so it is the one line the indent must not move.
---@param text string
---@param fn fun(line: string): string
---@return string
local function map_lines_after_first(text, fn)
    return (text:gsub("\n([^\n]*)", function(line)
        return "\n" .. fn(line)
    end))
end

--- Prepend `indent` to every line of `starter` after the first.
---
--- The first line is already sitting behind the template's own indentation, so
--- indenting it again would double it. Blank and whitespace-only lines are left
--- alone rather than padded out to trailing whitespace.
---@param starter string
---@param indent string
---@return string
local function reindent(starter, indent)
    if indent == "" then
        return starter
    end
    return map_lines_after_first(starter, function(line)
        -- Blank and whitespace-only lines stay as they are rather than being
        -- padded out to trailing whitespace.
        return line:match("^[ \t]*$") and line or indent .. line
    end)
end

--- Replace every token occurrence with `starter`, re-indented to match.
---
--- Hand-rolled rather than gsub because both of gsub's replacement forms are
--- wrong here. As a string it would treat `%` in the injected code as an escape
--- — `%1` expands to the whole match and `%%` collapses to `%` — which silently
--- mangles real starter code (erlang and prolog use `%` for comments). As a
--- function it cannot see where its match started, and the indent depends on
--- that position. Walking the string gives both: verbatim injection, and a
--- per-occurrence indent. Scanning resumes past the injected text, so a
--- `{{starter}}` inside it is never rescanned.
---@param template string
---@param starter string
---@return string
local function substitute(template, starter)
    local out, pos = {}, 1
    while true do
        -- plain find: braces are not Lua pattern metacharacters, but the token
        -- is matched literally regardless of what it is ever changed to.
        local first, last = template:find(M.STARTER_TOKEN, pos, true)
        if not first then
            out[#out + 1] = template:sub(pos)
            return table.concat(out)
        end
        out[#out + 1] = template:sub(pos, first - 1)
        out[#out + 1] = reindent(starter, indent_before(template, first))
        pos = last + 1
    end
end

--- Inverse of `reindent`: drop one level of the indentation the token added.
---
--- Only where it is actually present, so a line the user re-indented themselves
--- comes back as they left it rather than losing characters.
---@param text string
---@param indent string
---@return string
local function unindent(text, indent)
    if indent == "" then
        return text
    end
    return map_lines_after_first(text, function(line)
        -- Only where the indent is actually present, so a line the user
        -- re-indented themselves comes back as they left it.
        return line:sub(1, #indent) == indent and line:sub(#indent + 1) or line
    end)
end

--- Stands in for the user's code while the template is taken apart. Control
--- characters, so it cannot collide with anything a template legitimately
--- contains.
local SENTINEL = "\1codewars.nvim\1"

--- The template split into the text before and after the user's code.
---
--- Renders with a sentinel rather than reading the raw spec, so a function
--- template that interpolates `ctx.starter` itself is handled the same as one
--- that leaves `{{starter}}` in place.
---
--- Deliberately does NOT consult the switch: strip() is called precisely when
--- templates are being turned off, and wrap() right after they are turned on.
---@param lang string
---@param ctx table?
---@return { prefix: string, suffix: string, indent: string }? wrapper, string? reason
local function wrapper(lang, ctx)
    local spec = configured_spec(lang)
    if not spec then
        return nil, ("No %s template is configured."):format(lang)
    end

    local resolved = vim.tbl_extend("keep", ctx or {}, {
        lang = lang,
        ext = extension_for(lang),
        starter = SENTINEL,
    })

    local template = evaluate(spec, resolved)
    if not template then
        return nil, ("Your %s template produced nothing to wrap with."):format(lang)
    end

    local rendered = substitute(template, SENTINEL)
    local first, last = rendered:find(SENTINEL, 1, true)
    if not first then
        return nil, ("Your %s template has no %s, so it replaces your code rather than wrapping it.")
            :format(lang, M.STARTER_TOKEN)
    end
    if rendered:find(SENTINEL, last + 1, true) then
        return nil, ("Your %s template has more than one %s, so there is no single place your code lives.")
            :format(lang, M.STARTER_TOKEN)
    end

    return {
        prefix = rendered:sub(1, first - 1),
        suffix = rendered:sub(last + 1),
        indent = indent_before(rendered, first),
    }
end

--- Drop trailing newlines.
---
--- Vim treats a file's last newline as the line terminator, not as an empty
--- line, so a template written as `[[...\n]]` comes back from the buffer one
--- newline shorter than it went out. Comparing raw would make every template
--- ending in a newline — which is most of them — fail to match its own buffer.
---@param text string
---@return string
local function chomp(text)
    return (text:gsub("\n+$", ""))
end

--- Takes text ALREADY chomped, so callers that need the chomped form for
--- something else do not pay for a second pass over the whole buffer.
---@param body string chomped text
---@param w table
---@return boolean
local function is_wrapped(body, w)
    if body:sub(1, #w.prefix) ~= w.prefix then
        return false
    end
    local suffix = chomp(w.suffix)
    return suffix == "" or body:sub(-#suffix) == suffix
end

--- Put `text` inside the language's template, as if it were the kata's starter.
---@param lang string
---@param text string current buffer contents
---@param ctx table? kata metadata for function templates
---@return string? wrapped, string? reason
function M.wrap(lang, text, ctx)
    local w, reason = wrapper(lang, ctx)
    if not w then
        return nil, reason
    end
    if is_wrapped(chomp(text), w) then
        return nil, ("This buffer already starts from your %s template."):format(lang)
    end
    -- Chomped so wrap and strip are exact inverses in buffer space: a template
    -- ending in a newline would otherwise add a blank last line each round.
    return chomp(w.prefix .. reindent(text, w.indent) .. w.suffix)
end

--- Take `text` back out of the language's template.
---
--- Byte-exact or nothing. Once the buffer has been edited, no rule reliably
--- says which lines came from the template, and a wrong guess deletes work.
--- Refusing with a reason is the only honest failure here.
---@param lang string
---@param text string current buffer contents
---@param ctx table? kata metadata for function templates
---@return string? stripped, string? reason
function M.strip(lang, text, ctx)
    local w, reason = wrapper(lang, ctx)
    if not w then
        return nil, reason
    end
    local body = chomp(text)
    if not is_wrapped(body, w) then
        return nil, ("This buffer no longer matches your %s template, so nothing was removed."):format(lang)
    end

    local suffix = chomp(w.suffix)
    return unindent(body:sub(#w.prefix + 1, #body - #suffix), w.indent)
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

--- Whether the user configured a template for this language.
---
--- Independent of the switch: callers that want "will one actually be applied"
--- say `is_enabled() and is_configured()`, which is two plain reads rather than
--- a second near-identical predicate whose name hides the difference.
---
--- A predicate rather than a render: callers use this to decide whether to
--- mention a template they are NOT applying, so evaluating a function spec
--- here would run user code for a buffer that is never written.
---@param lang string
---@return boolean
function M.is_configured(lang)
    return configured_spec(lang) ~= nil
end

--- Starter text for a solution buffer.
---@param lang string language slug
---@param ctx table `{ starter = string, lang?, ext?, slug?, name?, rank?, tags? }`
---@return string
function M.render(lang, ctx)
    ctx = ctx or {}
    local starter = ctx.starter or ""

    if not M.is_enabled() then
        return starter
    end

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
        -- Absence of the token is not absence of the signature: a function
        -- template can splice `ctx.starter` in itself. Warning on the token
        -- alone told those users their signature had been dropped while it sat
        -- in the buffer in front of them.
        if starter ~= "" and not template:find(starter, 1, true) then
            warn_dropped_signature(lang, resolved)
        end
        return template
    end

    return substitute(template, starter)
end

return M
