local kumite = require("codewars.api.kumite")

local SERVER_ID = "6a63d4fba3713e60b587d2f3" -- 24 hex
local LOCAL_ID = "local-12345"

describe("kumite.is_server_id", function()
    it("accepts a 24-hex snippet id", function()
        assert.is_true(kumite.is_server_id(SERVER_ID))
    end)
    it("rejects local ids, nil, and non-hex / wrong length", function()
        assert.is_false(kumite.is_server_id(LOCAL_ID))
        assert.is_false(kumite.is_server_id(nil))
        assert.is_false(kumite.is_server_id("abc"))
        assert.is_false(kumite.is_server_id(string.rep("z", 24))) -- 24 chars, not hex
    end)
end)

describe("kumite.draft_payload", function()
    it("wraps fields under code_snippet; example_fixture mirrors fixture", function()
        local cs = kumite.draft_payload({
            language = "python", language_version = "3.11", test_framework = "cw-2",
            title = "T", description = "D", code = "a=1", fixture = "F",
            ["package"] = "", parent_id = "P", secret = true,
        }).code_snippet
        assert.are.equal("python", cs.language)
        assert.are.equal("3.11", cs.language_version)
        assert.are.equal("F", cs.fixture)
        assert.are.equal("F", cs.example_fixture)
        assert.are.equal("P", cs.parent_id)
        assert.is_true(cs.secret)
        assert.are.equal("", cs.user_tags)
    end)

    it("defaults absent fields and coerces secret to a boolean", function()
        local cs = kumite.draft_payload({ language = "ruby" }).code_snippet
        assert.are.equal("cw-2", cs.test_framework)
        assert.are.equal("", cs.fixture)
        assert.are.equal("", cs.example_fixture)
        assert.is_false(cs.secret) -- nil secret -> false, never sent as nil
    end)

    it("prefers an explicit example_fixture over the fixture mirror", function()
        local cs = kumite.draft_payload({ fixture = "F", example_fixture = "E" }).code_snippet
        assert.are.equal("E", cs.example_fixture)
    end)
end)

describe("kumite.save_draft", function()
    local calls
    local function stub(response, err)
        calls = {}
        local function mk(m)
            return function(endpoint, opts)
                table.insert(calls, { method = m, endpoint = endpoint, body = opts.body })
                opts.callback(response, err)
            end
        end
        package.loaded["codewars.api.utils"] = { post = mk("post"), put = mk("put") }
    end

    it("CREATEs via POST /kumite for a nil id and returns the new id", function()
        stub({ success = true, id = SERVER_ID, url = "/kumite/" .. SERVER_ID .. "/edit" })
        local got
        kumite.save_draft(nil, { language = "python", fixture = "F" },
            function(res, err) got = { res = res, err = err } end)
        assert.are.equal("post", calls[1].method)
        assert.are.equal("/kumite", calls[1].endpoint)
        assert.is_table(calls[1].body.code_snippet)
        assert.is_nil(got.err)
        assert.are.equal(SERVER_ID, got.res.id)
    end)

    it("treats a local id as CREATE, not UPDATE", function()
        stub({ success = true, id = SERVER_ID })
        kumite.save_draft(LOCAL_ID, { language = "python" }, function() end)
        assert.are.equal("post", calls[1].method)
        assert.are.equal("/kumite", calls[1].endpoint)
    end)

    it("UPDATEs via PUT /kumite/{id} for a server id and echoes the id back", function()
        stub({ success = true }) -- update response carries no id
        local got
        kumite.save_draft(SERVER_ID, { language = "python", fixture = "F" },
            function(res, err) got = { res = res, err = err } end)
        assert.are.equal("put", calls[1].method)
        assert.are.equal("/kumite/" .. SERVER_ID, calls[1].endpoint)
        assert.is_nil(got.err)
        assert.are.equal(SERVER_ID, got.res.id)
    end)

    it("surfaces a field validation error when success is false", function()
        stub({ success = false, fields = { code_snippet = { title = { errors = { "can't be blank" } } } } })
        local got_err
        kumite.save_draft(nil, { language = "python" }, function(_, err) got_err = err end)
        assert.truthy(got_err.msg:match("title"))
        assert.truthy(got_err.msg:match("blank"))
    end)

    it("passes through transport/auth errors untouched", function()
        stub(nil, { msg = "Session expired", auth = true })
        local got_err
        kumite.save_draft(SERVER_ID, { language = "python" }, function(_, err) got_err = err end)
        assert.is_true(got_err.auth)
    end)
end)
