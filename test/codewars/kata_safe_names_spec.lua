--- A kata slug, a kata id and a picked file name all become part of a path:
--- the solution file in storage.home, the session cache beside it. Each can
--- come from a Codewars reply or from what the user typed, so none may carry
--- a separator or `..` out of those directories. Every assertion about a
--- hostile name also checks the whole sandbox: nothing may be created
--- anywhere, not just inside storage.home.
local P = require("plenary.path")
local uv = vim.uv or vim.loop

local root = vim.fn.tempname()
local home_dir, cache_dir = root .. "/home", root .. "/cache"
vim.fn.mkdir(home_dir, "p")
vim.fn.mkdir(cache_dir, "p")

local errors = {}
package.loaded["codewars.logger"] = {
    info = function() end,
    warn = function() end,
    error = function(msg) errors[#errors + 1] = tostring(msg) end,
    err = function() end,
    debug = function() end,
}

local cfg = {
    user = { templates = { solution = {} }, indent = {}, testcase = { open_on_enter = false } },
    lang = "python",
    langs = require("codewars.config.langs"),
    storage = { home = P:new(home_dir), cache = P:new(cache_dir) },
}
package.loaded["codewars.config"] = cfg
_Cw_state = _Cw_state or {}
_Cw_state.katas = _Cw_state.katas or {}

local api = require("codewars.api.kata")
local get_calls, get_reply = 0, nil
api.get = function(_, cb)
    get_calls = get_calls + 1
    cb(get_reply, nil)
end

local train_calls = 0
package.loaded["codewars.api.train"] = {
    start = function() train_calls = train_calls + 1 end,
}

local Kata = require("codewars-ui.kata")
local session_cache = require("codewars.cache.session")

local HEX = "5264d2b162488dc400000001"

--- Every path under `dir`, with its kind and size, so a change to a file's
--- contents shows as well as a new or missing file.
---@param dir string
---@param found string[]?
---@return string[]
local function tree(dir, found)
    found = found or {}
    local handle = uv.fs_scandir(dir)
    while handle do
        local name, kind = uv.fs_scandir_next(handle)
        if not name then break end
        local path = dir .. "/" .. name
        local stat = uv.fs_lstat(path)
        found[#found + 1] = ("%s %s %d"):format(path, kind, stat and stat.size or -1)
        if kind == "directory" then tree(path, found) end
    end
    table.sort(found)
    return found
end

local function snapshot() return tree(root) end

local function read(path)
    return table.concat(vim.fn.readfile(path), "\n")
end

--- The cache creates its sessions directory on first use; make that happen
--- before a snapshot, so only what the call under test does shows in it.
local function warm_up_session_cache()
    session_cache.save("warm-up", "python", {})
    session_cache.delete("warm-up", "python")
end

local function write(path, text)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(vim.split(text, "\n"), path)
end

describe("a kata with a slug that cannot name a file", function()
    -- A slug that was passed but is not a string (`false`, a number, a table)
    -- was given, and is as invalid as one with a `/` in it.
    local BAD = {
        "../evil", "a/b", "..", "", "a\\b", "a b", "evil.py", "../" .. HEX, HEX .. "/x", "a\nb",
        false, true, 0, 12, {},
    }

    before_each(function()
        errors, get_calls, train_calls, get_reply = {}, 0, 0, nil
    end)

    for _, slug in ipairs(BAD) do
        local label = vim.inspect(slug)

        it(("%s is refused on mount: no request, no file, an error naming the slug"):format(label), function()
            local before = snapshot()
            local katas_before = #_Cw_state.katas
            local kata = Kata:new(slug, "python")
            kata._on_mounted = function() end

            assert.has_no.errors(function() kata:mount() end)

            assert.are.equal(0, get_calls, "asked Codewars for a slug that cannot be a slug")
            assert.are.equal(0, train_calls)
            assert.are.same(before, snapshot(), "created or changed a file")
            assert.are.equal(katas_before, #_Cw_state.katas, "mounted it anyway")
            assert.is_nil(kata._on_mounted, "left the continuation armed")
            assert.are.equal(1, #errors, vim.inspect(errors))
            assert.truthy(errors[1]:find("slug", 1, true), errors[1])
            assert.truthy(errors[1]:find(vim.inspect(slug), 1, true), errors[1])
        end)

        it(("%s cannot reach a file by way of Kata:path"):format(label), function()
            local before = snapshot()
            local ok, err = pcall(function() return Kata:new(slug, "python"):path() end)

            assert.is_false(ok, "wrote or opened a solution file for it")
            assert.truthy(tostring(err):find("slug", 1, true), tostring(err))
            assert.are.same(before, snapshot(), "created or changed a file")
        end)

        it(("%s is refused for the session cache too"):format(label), function()
            warm_up_session_cache()
            local before = snapshot()
            assert.is_nil(session_cache.get(slug, "python"))
            session_cache.save(slug, "python", { name = "x" })
            assert.are.same(before, snapshot(), "the session cache wrote a file for it")
            assert.is_nil(session_cache.get(slug, "python"))
            session_cache.delete(slug, "python")
        end)
    end

    it("is refused when none was passed at all", function()
        local before = snapshot()
        local kata = Kata:new(nil, "python")
        assert.has_no.errors(function() kata:mount() end)
        assert.are.equal(0, get_calls)
        assert.are.same(before, snapshot())
        assert.are.equal(1, #errors, vim.inspect(errors))
        assert.truthy(errors[1]:find("slug", 1, true), errors[1])
    end)

    it("is refused when Codewars is the one that sends it", function()
        get_reply = { id = HEX, slug = "../evil", languages = { "python" } }
        local before = snapshot()
        local kata = Kata:new("valid-braces", "python")
        kata._on_mounted = function() end

        assert.has_no.errors(function() kata:mount() end)

        assert.are.equal(1, get_calls)
        assert.are.equal(0, train_calls, "went on to start a session for it")
        assert.are.same(before, snapshot(), "created or changed a file")
        assert.is_nil(kata._on_mounted)
        assert.are.equal(1, #errors, vim.inspect(errors))
        assert.truthy(errors[1]:find("slug", 1, true), errors[1])
    end)

    -- A reply that names the kata at all is Codewars' answer, so an empty or
    -- non-string slug is an invalid one, not a missing one.
    for _, sent in ipairs({ "", false, true, 0, 12, { "../evil" } }) do
        it(("is refused when Codewars sends the slug %s"):format(vim.inspect(sent)), function()
            get_reply = { id = HEX, slug = sent, languages = { "python" } }
            local before = snapshot()
            local kata = Kata:new("valid-braces", "python")
            kata._on_mounted = function() end

            assert.has_no.errors(function() kata:mount() end)

            assert.are.equal(1, get_calls)
            assert.are.equal(0, train_calls, "went on to start a session for it")
            assert.are.same(before, snapshot(), "created or changed a file")
            assert.is_nil(kata._on_mounted, "left the continuation armed")
            assert.are.equal("valid-braces", kata.slug, "adopted the invalid slug")
            assert.are.equal(1, #errors, vim.inspect(errors))
            assert.truthy(errors[1]:find("slug", 1, true), errors[1])
            assert.truthy(errors[1]:find(vim.inspect(sent), 1, true), errors[1])
        end)
    end

    -- No `slug` field at all means the reply did not name the kata, which is
    -- not the same as naming it with nothing: the slug asked for, already
    -- checked, stands.
    it("keeps the requested slug when Codewars sends none", function()
        get_reply = { id = HEX, languages = { "python" } }
        local before = snapshot()
        local kata = Kata:new("valid-braces", "python")

        assert.has_no.errors(function() kata:mount() end)

        assert.are.equal(1, train_calls, "refused a reply with no slug")
        assert.are.equal("valid-braces", kata.slug)
        assert.are.same({}, errors)
        assert.are.same(before, snapshot())
    end)

    it("refuses a language that cannot name a session file", function()
        for _, lang in ipairs({ "../../evil", "a/b", "", "x y" }) do
            warm_up_session_cache()
            local before = snapshot()
            session_cache.save("valid-braces", lang, { name = "x" })
            assert.are.same(before, snapshot(), vim.inspect(lang))
            assert.is_nil(session_cache.get("valid-braces", lang), vim.inspect(lang))
        end
    end)
end)

describe("a kata with an ordinary slug", function()
    before_each(function()
        errors, get_calls, train_calls, get_reply = {}, 0, 0, nil
    end)

    for _, slug in ipairs({ "valid-braces", "Snake_case-9", HEX, "a" }) do
        it(("%s still opens its own file in storage.home"):format(slug), function()
            local kata = Kata:new(slug, "python")
            kata.setup_code = "def f():\n    pass"
            local path, existed = kata:path()

            assert.are.equal(vim.fn.resolve(home_dir) .. "/" .. slug .. ".py", vim.fn.resolve(path))
            assert.is_false(existed)
            assert.are.same({}, errors)
            assert.are.equal(1, vim.fn.filereadable(path))
        end)
    end

    it("saves and reads its session", function()
        session_cache.save("valid-braces", "python", { name = "Valid Braces" })
        assert.are.equal("Valid Braces", session_cache.get("valid-braces", "python").name)
        session_cache.delete("valid-braces", "python")
        assert.is_nil(session_cache.get("valid-braces", "python"))
    end)
end)

describe("the file named after a kata's id", function()
    local legacy_n = 0

    before_each(function()
        errors = {}
    end)

    local function open_with_id(slug, id)
        local kata = Kata:new(slug, "python")
        kata.kata_id = id
        kata.setup_code = "def f():\n    pass"
        return kata
    end

    it("still opens when the id is a real one and there is no file by the slug", function()
        write(home_dir .. "/" .. HEX .. ".py", "mine")
        local kata = open_with_id("legacy-one", HEX)
        kata:path()
        assert.are.equal(HEX .. ".py", kata._file_name)
        assert.are.equal("mine", read(kata.file:absolute()))
        assert.is_false(P:new(home_dir .. "/legacy-one.py"):exists())
    end)

    for _, id in ipairs({ "../" .. HEX, HEX .. "/x", "../" .. ("a"):rep(24), ("a"):rep(23), ("a"):rep(25) }) do
        it(("is not looked up for the id %s"):format(vim.inspect(id)), function()
            -- Where `<id>.py` would land if the id were trusted as a path.
            local outside = vim.fn.fnamemodify(home_dir .. "/" .. id .. ".py", ":p")
            write(outside, "OUTSIDE")
            legacy_n = legacy_n + 1
            local slug = "legacy-" .. legacy_n
            local kata = open_with_id(slug, id)

            kata:path()

            assert.are.equal(slug .. ".py", kata._file_name, "opened the id's file")
            assert.are.equal("OUTSIDE", read(outside), "wrote into the file the id pointed at")
            vim.fn.delete(outside)
        end)
    end
end)

describe("a file picked from a list", function()
    before_each(function()
        errors, get_calls, train_calls, get_reply = {}, 0, 0, nil
    end)

    local function picked(slug, file, lang)
        local kata = Kata:new(slug, lang or "python", { file = file })
        kata.kata_id = HEX
        kata.setup_code = "def f():\n    pass"
        return kata
    end

    -- `file` given as `false`, `true`, a number, `""` or a table was given,
    -- and is refused like a bad string: only an absent one means "not picked".
    local BAD_FILES = {
        "../x.py", "a/b.py", "/etc/x.py", "..\\x.py", "a\\b.py", "x..py", "x.y.py", ".py", "x.py/",
        false, true, 0, "", {},
    }
    for _, file in ipairs(BAD_FILES) do
        local label = vim.inspect(file)

        it(("%s is refused on mount: no request, no file, an error naming it"):format(label), function()
            write(root .. "/x.py", "OUTSIDE")
            write(home_dir .. "/a/b.py", "NESTED")
            local before = snapshot()

            assert.has_no.errors(function() picked("valid-braces", file):mount() end)

            assert.are.equal(0, get_calls)
            assert.are.same(before, snapshot(), "created or changed a file")
            assert.are.equal(1, #errors, vim.inspect(errors))
            assert.truthy(errors[1]:find("file", 1, true), errors[1])
            assert.truthy(errors[1]:find(vim.inspect(file), 1, true), errors[1])
        end)

        it(("%s cannot reach a file by way of Kata:path"):format(label), function()
            write(root .. "/x.py", "OUTSIDE")
            write(home_dir .. "/a/b.py", "NESTED")
            local before = snapshot()

            local kata = picked("valid-braces", file)
            local ok, err = pcall(function() return kata:path() end)

            assert.is_false(ok, "opened a file by a name that is not a plain file name")
            assert.truthy(tostring(err):find("file", 1, true), tostring(err))
            assert.are.same(before, snapshot(), "created or changed a file")
            assert.are.equal("OUTSIDE", read(root .. "/x.py"))
            assert.are.equal("NESTED", read(home_dir .. "/a/b.py"))
        end)
    end

    it("is ignored, not opened, when its extension is another language's", function()
        write(home_dir .. "/other.js", "JS")
        local kata = picked("valid-braces", "other.js")

        kata:path()

        assert.are.equal("valid-braces.py", kata._file_name)
        assert.are.equal("JS", read(home_dir .. "/other.js"))
        assert.are.same({}, errors)
    end)

    it("still opens a plain file name of this language", function()
        write(home_dir .. "/" .. HEX .. ".py", "the id one")
        write(home_dir .. "/valid-braces.py", "the slug one")
        local kata = picked("valid-braces", HEX .. ".py")

        kata:path()

        assert.are.equal(HEX .. ".py", kata._file_name)
        assert.are.equal("the id one", read(kata.file:absolute()))
        assert.are.same({}, errors)
    end)

    -- Only a `file` that is absent means "not picked".
    local NOT_GIVEN = {
        function(slug) return Kata:new(slug, "python") end,
        function(slug) return Kata:new(slug, "python", {}) end,
        function(slug) return Kata:new(slug, "python", { file = nil }) end,
    }
    for form, build in ipairs(NOT_GIVEN) do
        it(("opens the slug's own file when no file was given (form %d)"):format(form), function()
            local slug = "not-picked-" .. form
            local kata = build(slug)
            kata.setup_code = "def f():\n    pass"

            kata:path()

            assert.are.equal(slug .. ".py", kata._file_name)
            assert.are.equal(1, vim.fn.filereadable(home_dir .. "/" .. slug .. ".py"))
            assert.are.same({}, errors)
        end)
    end
end)

-- The language is joined into the session file name and picks the solution's
-- extension, so it is judged like the slug: as given, nil being the only way
-- to ask for the default.
describe("a kata with a language that cannot name a file", function()
    before_each(function()
        errors, get_calls, train_calls, get_reply = {}, 0, 0, nil
    end)

    for _, lang in ipairs({ false, true, 0, "", {}, "../evil", "a/b", "x y" }) do
        local label = vim.inspect(lang)

        it(("%s is refused on mount: no request, no file, an error naming it"):format(label), function()
            local before = snapshot()
            local kata = Kata:new("valid-braces", lang)
            kata._on_mounted = function() end

            assert.has_no.errors(function() kata:mount() end)

            assert.are.equal(0, get_calls)
            assert.are.same(before, snapshot(), "created or changed a file")
            assert.is_nil(kata._on_mounted)
            assert.are.equal(1, #errors, vim.inspect(errors))
            assert.truthy(errors[1]:find("language", 1, true), errors[1])
            assert.truthy(errors[1]:find(label, 1, true), errors[1])
        end)

        it(("%s cannot reach a file by way of Kata:path"):format(label), function()
            local before = snapshot()
            local ok, err = pcall(function() return Kata:new("valid-braces", lang):path() end)
            assert.is_false(ok)
            assert.truthy(tostring(err):find("language", 1, true), tostring(err))
            assert.are.same(before, snapshot(), "created or changed a file")
        end)
    end

    it("defaults to the configured language only when none was given", function()
        local kata = Kata:new("default-lang")
        kata.setup_code = "def f():\n    pass"
        assert.are.equal("python", kata.lang)
        kata:path()
        assert.are.equal("default-lang.py", kata._file_name)
        assert.are.same({}, errors)
    end)

    it("is refused when Codewars is the one that names the fallback language", function()
        for _, sent in ipairs({ "../evil", "a/b", "", false, 0, {} }) do
            errors, train_calls = {}, 0
            get_reply = { id = HEX, slug = "valid-braces", languages = { sent } }
            local before = snapshot()
            local kata = Kata:new("valid-braces", "python")
            kata._on_mounted = function() end

            assert.has_no.errors(function() kata:mount() end)

            assert.are.equal(0, train_calls, "went on to start a session for " .. vim.inspect(sent))
            assert.are.same(before, snapshot(), "created or changed a file")
            assert.is_nil(kata._on_mounted)
            assert.are.equal("python", kata.lang, "adopted " .. vim.inspect(sent))
            assert.are.equal(1, #errors, vim.inspect(errors))
            assert.truthy(errors[1]:find("language", 1, true), errors[1])
        end
    end)

    it("still falls back to a language Codewars lists that can name a file", function()
        get_reply = { id = HEX, slug = "valid-braces", languages = { "ruby" } }
        local kata = Kata:new("valid-braces", "python")

        assert.has_no.errors(function() kata:mount() end)

        assert.are.equal(1, train_calls)
        assert.are.equal("ruby", kata.lang)
        assert.are.same({}, errors)
    end)
end)
