-- Shared stubs for the pure/logic P2 modules (no nui / UI needed).
package.loaded["codewars.logger"] = package.loaded["codewars.logger"] or {
    info = function() end, warn = function() end, error = function() end,
    err = function() end, debug = function() end,
}
package.loaded["codewars.icons"] = package.loaded["codewars.icons"] or {
    get = function() return { test_passed = "P", test_failed = "F", all_passed = "✓", tests_failed = "✗" } end,
}
package.loaded["codewars.config"] = package.loaded["codewars.config"] or {
    user = { keys = { toggle = { "q" } }, debug = false }, lang = "python",
}

describe("kumite.runner", function()
    local submit_args, submit_response
    package.loaded["codewars.api.attempt"] = {
        submit = function(code, lang, fixture, tf, relay, ver, opts, cb)
            submit_args = { code = code, lang = lang, fixture = fixture, tf = tf, relay = relay, ver = ver, opts = opts }
            cb(submit_response.res, submit_response.err)
        end,
    }

    local runner = require("codewars.kumite.runner")

    -- Fake workspace + result popup capturing what the runner produces.
    local function make_ws(code, fixture)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(code, "\n"))
        return {
            bufnr = buf,
            lang = "python",
            snippet = { test_framework = "cw-2", language_version = nil, package = "" },
            fixture_content = function() return fixture end,
        }
    end

    local function make_result()
        local captured = {}
        return {
            handle = function(_, res) captured.handle = res end,
            handle_error = function(_, err) captured.handle_error = err end,
        }, captured
    end

    before_each(function()
        submit_args = nil
        submit_response = { res = nil, err = nil }
    end)

    it("shapes a passing run into a valid result", function()
        submit_response = { res = {
            result = { completed = true, passed = 3, failed = 0, errors = 0,
                output = { { t = "passed", v = "Test Passed" } } },
            wallTime = 42,
        } }
        local result, captured = make_result()
        runner.run(make_ws("print(1)", "assert True"), result)
        assert.is_true(captured.handle.valid)
        assert.are.equal(3, captured.handle.summary.passed)
        assert.are.equal(42, captured.handle.wall_time)
        assert.truthy(captured.handle.success_msg)
    end)

    it("passes code, fixture and no relay id to the runner", function()
        submit_response = { res = { result = { completed = true } } }
        local result = make_result()
        runner.run(make_ws("code here", "the fixture"), result)
        assert.are.equal("code here", submit_args.code)
        assert.are.equal("the fixture", submit_args.fixture)
        assert.is_nil(submit_args.relay)
    end)

    it("refuses to run with an empty fixture and never calls the runner", function()
        local result, captured = make_result()
        runner.run(make_ws("print(1)", "   "), result)
        assert.is_nil(submit_args)
        assert.truthy(captured.handle_error.msg:match("no test fixture"))
    end)

    it("surfaces runner errors via handle_error", function()
        submit_response = { res = nil, err = { msg = "runner exploded" } }
        local result, captured = make_result()
        runner.run(make_ws("print(1)", "assert True"), result)
        assert.are.equal("runner exploded", captured.handle_error.msg)
        assert.is_nil(captured.handle)
    end)

    it("falls back to the language default runtime when the snippet has none", function()
        -- Without this, Codewars runs Python under a legacy 2.7 runtime where
        -- `import codewars_test` fails. The snippet JSON never carries a version.
        submit_response = { res = { result = { completed = true } } }
        local result = make_result()
        runner.run(make_ws("print(1)", "assert True"), result) -- lang = python
        assert.are.equal("3.11", submit_args.ver)
    end)

    it("keeps an explicit snippet runtime version over the default", function()
        submit_response = { res = { result = { completed = true } } }
        local ws = make_ws("print(1)", "assert True")
        ws.snippet.language_version = "3.8"
        local result = make_result()
        runner.run(ws, result)
        assert.are.equal("3.8", submit_args.ver)
    end)
end)

describe("cache.kumite_stash", function()
    -- In-memory path-backed cache stub.
    local store = {}
    local function fake_path(name)
        return {
            name = name,
            absolute = function() return "/cache/" .. name end,
            exists = function() return store[name] ~= nil end,
            rm = function() store[name] = nil return true end,
        }
    end
    package.loaded["codewars.cache.utils"] = {
        cache_file = function(name) return fake_path(name) end,
        -- returns ok, mirroring the real cache_utils contract: the stash
        -- only reports a path when the write actually landed
        write_json = function(path, data)
            store[path.name] = vim.deepcopy(data)
            return true
        end,
        read_json = function(path) return store[path.name] end,
    }

    local stash = require("codewars.cache.kumite_stash")

    before_each(function()
        for k in pairs(store) do store[k] = nil end
    end)

    it("saves an entry keyed by id, stamping saved_at (UTC ISO)", function()
        local path = stash.save({ id = "abc", title = "T", language = "python",
            parent_id = nil, code = "x", fixture = "y" })
        assert.are.equal("/cache/kumite-stash-abc.json", path)
        local got = stash.get("abc")
        assert.are.equal("x", got.code)
        assert.truthy(got.saved_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))
    end)

    it("returns nil for a missing stash", function()
        assert.is_nil(stash.get("nope"))
    end)

    it("deletes an existing stash and reports absence", function()
        stash.save({ id = "gone", title = "T", language = "python", code = "c", fixture = "f" })
        assert.is_true(stash.delete("gone"))
        assert.is_nil(stash.get("gone"))
        assert.is_false(stash.delete("gone"))
    end)
end)

describe("languages.filetypes", function()
    local ft = require("codewars.languages.filetypes")

    it("maps codewars slugs to real Neovim filetype names, not extensions", function()
        assert.are.equal("python", ft.code("python"))   -- not "py"
        assert.are.equal("ruby", ft.code("ruby"))        -- not "rb"
        assert.are.equal("rust", ft.code("rust"))        -- not "rs"
        assert.are.equal("cs", ft.code("csharp"))
        assert.are.equal("haskell", ft.code("haskell"))
    end)

    it("covers languages beyond the 32 configured for training", function()
        assert.are.equal("cobol", ft.code("cobol"))
        assert.are.equal("agda", ft.code("agda"))
        assert.are.equal("lisp", ft.code("commonlisp"))
        assert.are.equal("cf", ft.code("cfml"))
    end)

    it("returns nil for languages with no Neovim grammar", function()
        assert.is_nil(ft.code("bf"))
        assert.is_nil(ft.code("lambdacalc"))
        assert.is_nil(ft.code("totally-made-up"))
    end)

    it("uses the server testLanguage for the fixture when provided", function()
        -- a java solution whose fixture the server reports as java
        assert.are.equal("java", ft.test("java", "java"))
    end)

    it("derives cross-language fixtures (BF/SQL/NASM) when testLanguage is absent", function()
        assert.are.equal("javascript", ft.test("bf"))     -- BF tests are JS
        assert.are.equal("ruby", ft.test("sql"))          -- SQL tests are Ruby
        assert.are.equal("c", ft.test("nasm"))            -- NASM tests are C
    end)

    it("falls back to the solution language for same-language fixtures", function()
        assert.are.equal("python", ft.test("python"))
    end)
end)

describe("languages.fixtures", function()
    local fx = require("codewars.languages.fixtures")

    it("returns the python starter with the codewars_test + solution import", function()
        local t = fx.get("python")
        assert.truthy(t:match("codewars_test"))
        assert.truthy(t:match("import solution"))
    end)

    it("provides templates keyed by the plugin's language slugs", function()
        assert.truthy(fx.get("java"):match("SolutionTest"))
        assert.truthy(fx.get("rust"):match("assert_eq!"))
        assert.truthy(fx.get("haskell"):match("Hspec"))
        assert.truthy(fx.get("csharp"):match("TestFixture"))
    end)

    it("returns empty for languages without a template and unknowns", function()
        assert.are.equal("", fx.get("nim"))
        assert.are.equal("", fx.get("nonexistent-lang"))
    end)

    it("trims the leading newline so the buffer starts at real content", function()
        assert.is_nil(fx.get("python"):match("^\n"))
    end)
end)

describe("cmd kumite P2 routing", function()
    package.loaded["codewars.config"] = {
        user = { keys = { toggle = { "q" } }, logging = false, debug = false, username = "prosk" },
        lang = "python",
        langs = { { slug = "python", lang = "Python", ft = "py", comment = "#" } },
    }
    local logged = {}
    package.loaded["codewars.logger"] = {
        info = function(m) table.insert(logged, { "info", m }) end,
        warn = function(m) table.insert(logged, { "warn", m }) end,
        error = function(m) table.insert(logged, { "error", m }) end,
        err = function(e) table.insert(logged, { "err", e }) end,
        debug = function() end,
    }

    local curr_kumite_ret
    local cookie_present = true
    local prompt_cb
    package.loaded["codewars.utils"] = {
        curr_kumite = function() return curr_kumite_ret end,
        curr_kata = function() return nil end,
        auth_guard = function() end,
    }
    package.loaded["codewars.cache.cookie"] = {
        get = function() return cookie_present and { csrf_token = "t", session_id = "s" } or nil end,
    }

    package.loaded["codewars.command"] = nil
    local cmd = require("codewars.command")
    -- cookie_prompt drives auth-resume; capture its callback.
    cmd.cookie_prompt = function(cb) prompt_cb = cb end

    before_each(function()
        logged = {}
        curr_kumite_ret = nil
        cookie_present = true
        prompt_cb = nil
    end)

    it("kumite fork routes to the current workspace's fork()", function()
        local forked = false
        curr_kumite_ret = { fork = function() forked = true end }
        cmd.exec({ name = "CW", args = "kumite fork" })
        assert.is_true(forked)
    end)

    it("kumite fork with no workspace errors", function()
        cmd.kumite_fork()
        assert.are.equal("error", logged[1][1])
        assert.truthy(logged[1][2]:match("No kumite here"))
    end)

    it(":CW test runs the kumite console when signed in", function()
        local ran
        curr_kumite_ret = { console = { run = function(_, mode) ran = mode end } }
        cmd.test()
        assert.are.equal("test", ran)
    end)

    it(":CW test on a kumite resumes after sign-in when signed out", function()
        cookie_present = false
        local ran
        curr_kumite_ret = { console = { run = function(_, mode) ran = mode end } }
        cmd.test()
        assert.is_nil(ran)            -- deferred to the prompt callback
        assert.is_function(prompt_cb)
        prompt_cb(true)               -- successful sign-in
        assert.are.equal("test", ran)
    end)

    it(":CW test cancel (sign-in dismissed) does not run", function()
        cookie_present = false
        local ran
        curr_kumite_ret = { console = { run = function(_, mode) ran = mode end } }
        cmd.test()
        prompt_cb(false)
        assert.is_nil(ran)
    end)

    describe("kumite new", function()
        local mounted
        before_each(function()
            mounted = nil
            package.loaded["codewars.picker"] = { pick_language = function(cb) cb("python") end }
            package.loaded["codewars.api.kumite"] = {
                default_framework = function() return "cw-2" end,
                default_version = function() return "3.11" end,
            }
            package.loaded["codewars-ui.kumite"] = {
                new = function(_, snippet, opts)
                    mounted = { snippet = snippet, opts = opts }
                    return { mount = function() end }
                end,
            }
        end)

        it("opens a blank local_new workspace with a local id and title", function()
            local real_input = vim.ui.input
            vim.ui.input = function(_, cb) cb("My Kumite") end
            cmd.kumite_new({})
            vim.ui.input = real_input
            assert.are.equal("My Kumite", mounted.snippet.title)
            assert.are.equal("python", mounted.snippet.language)
            assert.are.equal("cw-2", mounted.snippet.test_framework)
            assert.are.equal("3.11", mounted.snippet.language_version)
            assert.are.equal("local_new", mounted.opts.state)
            assert.truthy(mounted.snippet.id:match("^local%-"))
            -- fixture is prefilled from the starter template, not empty
            assert.truthy(mounted.snippet.fixture:match("codewars_test"))
        end)

        it("cancelling the title prompt mounts nothing", function()
            local real_input = vim.ui.input
            vim.ui.input = function(_, cb) cb(nil) end
            cmd.kumite_new({})
            vim.ui.input = real_input
            assert.is_nil(mounted)
        end)
    end)
end)
