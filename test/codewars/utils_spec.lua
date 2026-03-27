describe("utils", function()
    describe("parse_slug", function()
        -- Stub config to avoid full plugin init
        package.loaded["codewars.config"] = {
            user = { logging = false },
            langs = {},
        }
        package.loaded["codewars.logger"] = {
            info = function() end,
            warn = function() end,
            error = function() end,
            debug = function() end,
        }

        local utils = require("codewars.utils")

        it("extracts slug from full URL", function()
            local slug = utils.parse_slug("https://www.codewars.com/kata/multiply/train/python")
            assert.are.equal("multiply", slug)
        end)

        it("extracts slug from kata URL without train", function()
            local slug = utils.parse_slug("https://www.codewars.com/kata/some-kata-slug")
            assert.are.equal("some-kata-slug", slug)
        end)

        it("returns raw slug as-is", function()
            local slug = utils.parse_slug("multiply")
            assert.are.equal("multiply", slug)
        end)

        it("handles slug with hyphens", function()
            local slug = utils.parse_slug("two-to-one")
            assert.are.equal("two-to-one", slug)
        end)

        it("handles URL with hash ID", function()
            local slug = utils.parse_slug("https://www.codewars.com/kata/50654ddff44f800200000004")
            assert.are.equal("50654ddff44f800200000004", slug)
        end)
    end)

    describe("handle_res", function()
        local api_utils = require("codewars.api.utils")

        it("returns error for nil input", function()
            local res, err = api_utils.handle_res(nil)
            assert.is_nil(res)
            assert.is_not_nil(err)
            assert.truthy(err.msg:find("No response"))
        end)

        it("returns error for non-zero exit code", function()
            local res, err = api_utils.handle_res({ exit = 7, status = 0, body = "" })
            assert.is_nil(res)
            assert.is_not_nil(err)
            assert.are.equal(7, err.code)
            assert.truthy(err.msg:find("curl failed"))
        end)

        it("returns error for HTTP >= 300 with JSON reason", function()
            local body = vim.json.encode({ reason = "Not found" })
            local res, err = api_utils.handle_res({ exit = 0, status = 404, body = body })
            assert.is_not_nil(err)
            assert.are.equal(404, err.status)
            assert.truthy(err.msg:find("Not found"))
        end)

        it("returns auth error for HTTP 401", function()
            local body = vim.json.encode({ error = "Unauthorized" })
            local res, err = api_utils.handle_res({ exit = 0, status = 401, body = body })
            assert.is_not_nil(err)
            assert.are.equal(401, err.status)
            assert.truthy(err.auth)
            assert.truthy(err.msg:find("Session expired"))
        end)

        it("returns auth error for HTTP 403", function()
            local res, err = api_utils.handle_res({ exit = 0, status = 403, body = "Forbidden" })
            assert.is_not_nil(err)
            assert.are.equal(403, err.status)
            assert.truthy(err.auth)
        end)

        it("returns error for HTTP >= 300 with non-JSON body", function()
            local res, err = api_utils.handle_res({ exit = 0, status = 500, body = "Internal Server Error" })
            assert.is_not_nil(err)
            assert.are.equal(500, err.status)
        end)

        it("decodes JSON body on success", function()
            local body = vim.json.encode({ id = "abc", name = "Multiply" })
            local res, err = api_utils.handle_res({ exit = 0, status = 200, body = body })
            assert.is_nil(err)
            assert.are.equal("abc", res.id)
            assert.are.equal("Multiply", res.name)
        end)

        it("returns raw body when not valid JSON", function()
            local res, err = api_utils.handle_res({ exit = 0, status = 200, body = "<html>page</html>" })
            assert.is_nil(err)
            assert.are.equal("<html>page</html>", res)
        end)
    end)
end)
