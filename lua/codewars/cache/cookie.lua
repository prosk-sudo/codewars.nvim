local log = require("codewars.logger")
local cache_utils = require("codewars.cache.utils")

local cached_cookie = nil

-- Lua has no octal literals: 384 is 0600, read and write for the owner and
-- nothing for anyone else.
local OWNER_ONLY = 384

---@class cw.cache.Cookie
---@field csrf_token string
---@field session_id string
---@field str string

---@class cw.Cookie
local Cookie = {}

---@return Path
local function file()
    return cache_utils.cache_file("cookie")
end

--- Normalise one value pasted into its own box. DevTools shows each cookie
--- as a name/value row, so people arrive with a bare value, the whole row
--- ("CSRF-TOKEN=abc"), or a value still carrying the separator after it.
---@param value string?
---@param name string
---@return string
local function clean_field(value, name)
    local out = tostring(value or ""):match("^%s*(.-)%s*$")

    if out:sub(1, #name + 1):lower() == (name .. "="):lower() then
        out = out:sub(#name + 2)
    end

    out = out:gsub(";%s*$", "")
    return (out:match("^%s*(.-)%s*$"))
end

--- What a box contributes after normalisation, "" when it holds nothing
--- usable. Exposed so the prompt can refuse an empty first box before
--- opening the second, rather than asking for a second value and then
--- blaming the first.
---@param value string?
---@param name string
---@return string
function Cookie.clean_value(value, name)
    return clean_field(value, name)
end

--- Read a string that is a whole cookie header and nothing else.
---
--- parse() looks for its two markers ANYWHERE in a string, which is right for
--- reading back a file this module wrote but wrong for judging what a user
--- pasted: any prose carrying them reads as a cookie, this plugin's own
--- "Expected: CSRF-TOKEN=...; _session_id=...;" hint included, where `...`
--- satisfies `[^;]+`. Every `;`-separated part must be a real `name=value`
--- pair here, so unrelated cookies are tolerated but prose is not.
---@param str string?
---@return string? csrf, string? session
function Cookie.parse_header(str)
    local trimmed = tostring(str or ""):match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end

    local seen = {}
    for part in trimmed:gmatch("[^;]+") do
        local name, value = part:match("^%s*([%w%-_]+)%s*=%s*(.-)%s*$")
        if not name or value == "" then
            return nil
        end
        seen[name:lower()] = value
    end

    local csrf, session = seen["csrf-token"], seen["_session_id"]
    if not csrf or not session then
        return nil
    end
    return csrf, session
end

--- Set the cookie from the two values separately, so nobody has to assemble
--- the header by hand. Stores the same string Cookie.set does, which keeps
--- already-signed-in users and every reader of the file working unchanged.
---@param csrf string?
---@param session string?
---@return string? error
function Cookie.set_parts(csrf, session)
    -- The first box accepts a whole `CSRF-TOKEN=...; _session_id=...` paste,
    -- so the same clipboard reaching the second box is a natural mistake.
    -- It already carries both values; take it rather than splicing it in
    -- again as if it were one.
    local header_csrf, header_session = Cookie.parse_header(session)
    if header_csrf then
        -- Using it discards whatever the first box was given. That is fine
        -- when they agree, and not ours to decide when they do not: only the
        -- user knows which of the two is the live token.
        local typed = clean_field(csrf, "CSRF-TOKEN")
        if typed ~= "" and typed ~= header_csrf then
            return "The cookie pasted here carries a different CSRF-TOKEN than the first box. "
                .. "Run :CW cookie again and paste one or the other."
        end
        csrf, session = header_csrf, header_session
    end

    csrf = clean_field(csrf, "CSRF-TOKEN")
    session = clean_field(session, "_session_id")

    if csrf == "" then
        return "CSRF-TOKEN is empty. Paste the value of the CSRF-TOKEN cookie."
    end
    if session == "" then
        return "_session_id is empty. Paste the value of the _session_id cookie."
    end

    -- Inspect each value for what breaks a header BEFORE building one.
    -- parse() reports only that the header as a whole failed to read back, so
    -- asking it which half was at fault blames whichever branch is tested
    -- first -- telling someone to fix a `;` in a value that has none, while
    -- never naming the box that actually needs re-pasting.
    for _, field in ipairs({
        { value = csrf, name = "CSRF-TOKEN" },
        { value = session, name = "_session_id" },
    }) do
        if field.value:find(";", 1, true) then
            return field.name .. " value looks wrong. Paste only the value, without any `;`."
        end
        -- These are replayed verbatim into the Cookie: request header.
        if field.value:find("%c") then
            return field.name .. " value looks wrong. Paste only the value, without line breaks."
        end
    end

    local str = ("CSRF-TOKEN=%s; _session_id=%s"):format(csrf, session)

    -- Neither value carries a separator now, so a header that still fails to
    -- read back means a value embeds the other cookie's own name and shifts
    -- where parse() looks. Which field is to blame is genuinely ambiguous
    -- there, so say what happened rather than guess.
    local parsed = Cookie.parse(str)
    if not parsed or parsed.csrf_token ~= csrf or parsed.session_id ~= session then
        return "Those values could not be stored as a cookie. Paste each value exactly as the browser shows it."
    end

    return Cookie.set(str)
end

--- The dashboard has to hear about a sign-in or sign-out, whichever command
--- caused it: `:CW cookie` from the command line never goes near the menu.
--- Only after the file is final -- the menu reads the cookie back.
local function tell_menu()
    local ok, menu = pcall(require, "codewars-ui.renderer.menu")
    if ok and menu then pcall(menu.session_changed) end
end

--- Write the cookie so that only its owner can read it.
---
--- The file holds a live session, so any other local account that can read
--- it can act as this user. It is written to a new file of its own next to
--- the cookie, made private BEFORE the cookie goes in, and then renamed over
--- the cookie. Anything that opens the existing file instead gets it wrong:
--- the mode passed to open only applies when the file is created, and then
--- only after the umask is subtracted, so a world-readable file keeps its
--- mode; a read-only one cannot be opened for writing at all; opening it for
--- writing empties it before anything can go wrong; and looking at the path
--- and then opening it lets another process create the file in between. A
--- new file has none of those: it is exclusive, so nothing else is in it,
--- fchmod acts on the file we hold and ignores the umask, and the saved
--- cookie stays intact until the new one is complete.
---
--- Raises on failure, as Path:write did, with the previous cookie untouched
--- and the new file closed and removed.
---@param path string
---@param str string
local function write_private(path, str)
    local uv = vim.uv or vim.loop
    local tmp = ("%s.tmp.%d.%.0f"):format(path, uv.os_getpid(), uv.hrtime())
    local fd = assert(uv.fs_open(tmp, "wx", OWNER_ONLY))
    local ok, err = pcall(function()
        assert(uv.fs_fchmod(fd, OWNER_ONLY))
        -- fs_write returns how many bytes it stored, which can be fewer than
        -- it was given. Renaming a part-written file over the saved cookie
        -- would lose the session, so keep going until all of it is out, and
        -- give up on a call that stores nothing rather than retrying for ever.
        local written = 0
        while written < #str do
            local count = assert(uv.fs_write(fd, str:sub(written + 1), written))
            assert(count > 0, "short write: could not store the whole cookie")
            written = written + count
        end
    end)
    -- Closed whether or not the writes worked, so a failure leaks nothing.
    local closed, close_err = uv.fs_close(fd)
    if ok then
        ok, err = closed, close_err
    end
    if ok then
        ok, err = uv.fs_rename(tmp, path)
    end
    if not ok then
        uv.fs_unlink(tmp)
        error(err, 0)
    end
end

---@param str string
---@return string? error
function Cookie.set(str)
    local _, cerr = Cookie.parse(str)
    if cerr then
        return cerr
    end

    write_private(file():absolute(), str)
    cached_cookie = nil
    Cookie.identity_changed()
    tell_menu()
    log.info("Cookie saved successfully")
    return nil
end

--- Drop everything belonging to the signed-in identity, on sign-in and
--- sign-out. Anything missed here is served to the next account as if it were
--- theirs: cached solution ids, someone else's completed kata, a stale
--- username. Each lives in a different module, so this is the one place that
--- enumerates them.
---
--- Every hook is a pcall'd lazy require: this module must not pull the
--- UI/picker chain in at load time, and one that fails to load must not stop
--- the rest from being cleared.
function Cookie.identity_changed()
    local function with(mod, fn)
        local ok, m = pcall(require, mod)
        if ok and m then pcall(fn, m) end
    end

    -- The user's own votes are baked into the cached solutions pages.
    with("codewars.api.solutions", function(m) m.invalidate() end)
    -- completed.json / kata_details.json are keyed by the old username.
    with("codewars.cache.completed", function(m) m.clear() end)
    -- sessions/*.json hold the old account's project/solution ids.
    with("codewars.cache.session", function(m) m.clear_all() end)
    -- The picker memoises the completed set in memory.
    with("codewars.picker", function(m) m.invalidate_completed_cache() end)
    -- The remembered focus kata belongs to the old account's queue.
    with("codewars.command", function(m) m.forget_focus() end)
    -- Detected from the old dashboard; set() and delete() tell the menu,
    -- which detects it again.
    with("codewars.config", function(m) m.user.username = "" end)
    -- The same name persisted for next launch, plus that account's stats.
    with("codewars.cache.profile", function(m) m.clear() end)
    -- Not the menu: verify() calls this itself when it finds the cookie
    -- belongs to somebody else, and is already fetching the new identity.
end

---@return boolean removed
function Cookie.delete()
    Cookie.identity_changed()
    local f = file()
    local removed = f:exists() and (pcall(f.rm, f)) or false
    -- After the file is gone: anything above that read the cookie cached it
    -- again, and a sign-out that keeps serving the old cookie is none.
    cached_cookie = nil
    tell_menu()
    return removed
end

---@return cw.cache.Cookie?
function Cookie.get()
    if cached_cookie then
        return cached_cookie
    end

    local f = file()
    if not f:exists() then
        return
    end

    local contents = f:read()
    if not contents or type(contents) ~= "string" then
        return
    end

    contents = select(1, contents:gsub("^%s*(.-)%s*$", "%1"))
    local cookie = Cookie.parse(contents)
    if cookie then
        cached_cookie = cookie
    end
    return cookie
end

---@param str string
---@return cw.cache.Cookie?, string?
function Cookie.parse(str)
    local csrf = str:match("CSRF%-TOKEN=([^;]+)")
    if not csrf or csrf == "" then
        csrf = str:match("csrf%-token=([^;]+)")
    end
    if not csrf or csrf == "" then
        return nil, "Bad CSRF-TOKEN format. Expected: CSRF-TOKEN=...; _session_id=...;"
    end

    local session = str:match("_session_id=([^;]+)")
    if not session or session == "" then
        return nil, "Bad _session_id format. Expected: CSRF-TOKEN=...; _session_id=...;"
    end

    return { csrf_token = csrf, session_id = session, str = str }
end

return Cookie
