-- Users copy these two values out of the DevTools cookie table, where each
-- row shows a name and a value. Asking them to reassemble
-- `CSRF-TOKEN=...; _session_id=...` by hand is the step people get wrong, so
-- each value is accepted on its own and normalised here rather than being
-- validated as one string the user had to build.
describe("Cookie.set_parts", function()
    local Path = require("plenary.path")
    local real_utils = package.loaded["codewars.cache.utils"]
    local Cookie

    before_each(function()
        -- A scratch cache dir keyed by name: cache_file() is called by both the
        -- write and the read, and Cookie.set's identity_changed() clears the
        -- other cache files through it -- one shared path would delete the
        -- cookie we just wrote.
        local dir = Path:new(vim.fn.tempname())
        dir:mkdir({ parents = true })
        package.loaded["codewars.cache.utils"] = vim.tbl_extend("force", real_utils or {}, {
            cache_file = function(name) return dir:joinpath(name) end,
        })
        package.loaded["codewars.cache.cookie"] = nil
        Cookie = require("codewars.cache.cookie")
    end)
    after_each(function()
        package.loaded["codewars.cache.utils"] = real_utils
        package.loaded["codewars.cache.cookie"] = nil
    end)

    it("accepts two bare values", function()
        assert.is_nil(Cookie.set_parts("abc", "xyz"))

        local c = Cookie.get()
        assert.equals("abc", c.csrf_token)
        assert.equals("xyz", c.session_id)
    end)

    -- Chrome's "Copy value" is clean, but people also select the whole row.
    it("tolerates the cookie name being pasted along with the value", function()
        assert.is_nil(Cookie.set_parts("CSRF-TOKEN=abc", "_session_id=xyz"))

        local c = Cookie.get()
        assert.equals("abc", c.csrf_token)
        assert.equals("xyz", c.session_id)
    end)

    it("ignores case in a pasted cookie name", function()
        assert.is_nil(Cookie.set_parts("csrf-token=abc", "_SESSION_ID=xyz"))

        local c = Cookie.get()
        assert.equals("abc", c.csrf_token)
        assert.equals("xyz", c.session_id)
    end)

    it("strips surrounding whitespace and a trailing semicolon", function()
        assert.is_nil(Cookie.set_parts("  abc;  ", "\txyz; "))

        local c = Cookie.get()
        assert.equals("abc", c.csrf_token)
        assert.equals("xyz", c.session_id)
    end)

    it("names the empty field rather than the whole format", function()
        local err = Cookie.set_parts("", "xyz")
        assert.truthy(err)
        assert.truthy(err:find("CSRF-TOKEN", 1, true))

        err = Cookie.set_parts("abc", "   ")
        assert.truthy(err)
        assert.truthy(err:find("_session_id", 1, true))
    end)

    it("writes a cookie header the API layer can already read", function()
        assert.is_nil(Cookie.set_parts("abc", "xyz"))
        assert.equals("CSRF-TOKEN=abc; _session_id=xyz", Cookie.get().str)
    end)

    -- Box 1 advertises that a whole `CSRF-TOKEN=...; _session_id=...` paste
    -- works, so the same clipboard landing in box 2 is a natural mistake. It
    -- used to be spliced into the header a second time, where parse() read
    -- `_session_id=` at its FIRST occurrence and stored "CSRF-TOKEN=abc" as
    -- the session id -- reporting a successful sign-in that could not work.
    it("takes a whole header pasted into the second box at face value", function()
        assert.is_nil(Cookie.set_parts("abc", "CSRF-TOKEN=abc; _session_id=xyz"))

        local c = Cookie.get()
        assert.equals("abc", c.csrf_token)
        assert.equals("xyz", c.session_id)
    end)

    -- parse() looks for its markers ANYWHERE in a string, so any prose
    -- carrying them reads as a cookie -- including the plugin's own error
    -- text, where "..." satisfies `[^;]+`. Accepting that stores two literal
    -- dots as a session and calls it a successful sign-in.
    it("does not mistake prose containing the markers for a cookie", function()
        assert.is_nil(Cookie.parse_header(
            "Bad CSRF-TOKEN format. Expected: CSRF-TOKEN=...; _session_id=...;"))
        assert.is_nil(Cookie.parse_header("prefixCSRF-TOKEN=embedded;_session_id=sess"))

        assert.truthy(Cookie.set_parts("abc",
            "Bad CSRF-TOKEN format. Expected: CSRF-TOKEN=...; _session_id=...;"))
        assert.is_nil(Cookie.get())
    end)

    it("reads a real header, including one carrying unrelated cookies", function()
        local csrf, session = Cookie.parse_header("CSRF-TOKEN=abc; _session_id=xyz")
        assert.equals("abc", csrf)
        assert.equals("xyz", session)

        csrf, session = Cookie.parse_header("_ga=1; CSRF-TOKEN=abc; _session_id=xyz;")
        assert.equals("abc", csrf)
        assert.equals("xyz", session)
    end)

    -- Taking the header would throw away what the first box was given, with
    -- nothing said. When the two disagree, only the user knows which is live.
    it("refuses a header in the second box that contradicts the first", function()
        local err = Cookie.set_parts("TYPED_BY_HAND", "CSRF-TOKEN=DIFFERENT; _session_id=xyz")
        assert.truthy(err)
        assert.is_nil(Cookie.get())
    end)

    -- Same class: parse() reads up to the first `;`, so an interior one would
    -- store a value that reads back as a prefix of what was typed.
    it("refuses a value carrying a semicolon rather than truncating it", function()
        local err = Cookie.set_parts("ab;c", "xyz")
        assert.truthy(err)
        assert.truthy(err:find("CSRF-TOKEN", 1, true))
        assert.is_nil(Cookie.get())
    end)

    -- parse() reports only that the header as a whole did not read back, not
    -- which half broke it. Blaming the wrong box sends the user to re-paste a
    -- value that was never wrong, and never names the one that was.
    it("blames the second field when the second field is the broken one", function()
        local err = Cookie.set_parts("abc", ";xyz")
        assert.truthy(err)
        assert.truthy(err:find("_session_id", 1, true))
        assert.is_nil(err:find("CSRF-TOKEN", 1, true))
    end)

    it("blames the first field when the first field is the broken one", function()
        local err = Cookie.set_parts("ab;c", "xyz")
        assert.truthy(err)
        assert.truthy(err:find("CSRF-TOKEN", 1, true))
        assert.is_nil(err:find("_session_id", 1, true))
    end)

    -- A value carrying the other field's marker shifts where parse() looks,
    -- so the header reads back as something else entirely.
    it("refuses a value that embeds the other cookie's name", function()
        assert.truthy(Cookie.set_parts("abc_session_id=zzz", "xyz"))
        assert.is_nil(Cookie.get())
    end)

    -- These reach the Cookie: request header verbatim, so a stray newline in
    -- a paste must not be written to disk and replayed into every request.
    it("refuses a value carrying a control character", function()
        local err = Cookie.set_parts("ab\nc", "xyz")
        assert.truthy(err)
        assert.truthy(err:find("CSRF-TOKEN", 1, true))
        assert.is_nil(Cookie.get())

        err = Cookie.set_parts("abc", "x\ry")
        assert.truthy(err)
        assert.truthy(err:find("_session_id", 1, true))
        assert.is_nil(Cookie.get())
    end)

    -- The property behind both: what comes back out is what went in.
    it("never stores a header that reads back as something else", function()
        assert.is_nil(Cookie.set_parts("a-b_c%3D", "d.e-f"))

        local c = Cookie.get()
        assert.equals("a-b_c%3D", c.csrf_token)
        assert.equals("d.e-f", c.session_id)
    end)

    -- The first box still accepts the old combined paste, so the prompt can
    -- detect it and skip asking for the second value.
    it("still recognises a whole cookie string via parse", function()
        local c = Cookie.parse("CSRF-TOKEN=abc; _session_id=xyz")
        assert.equals("abc", c.csrf_token)
        assert.equals("xyz", c.session_id)

        assert.is_nil(Cookie.parse("abc"))
    end)
end)
