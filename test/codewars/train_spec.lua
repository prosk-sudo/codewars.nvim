-- api.train had no spec, and the review found it was the one transport
-- outside the cw.err contract: a raw plenary call with no on_error (raised
-- offline, mount stuck forever), a hardcoded /train/python page, no
-- auth/rate_limited flags, and a session table indexed without a type
-- check. It goes through page.fetch now; these pin each of those.
describe("api.train", function()
    package.loaded["codewars.logger"] = {
        info = function() end, warn = function() end, error = function() end,
        err = function() end, debug = function() end,
    }
    package.loaded["codewars.api.headers"] = { get = function() return {} end }

    package.loaded["codewars.api.train"] = nil
    local train = require("codewars.api.train")
    local page = require("codewars.api.page")
    local api_utils = require("codewars.api.utils")

    local real_fetch, real_post = page.fetch, api_utils.post
    local fetched, posted
    before_each(function()
        fetched, posted = {}, {}
    end)
    after_each(function()
        page.fetch, api_utils.post = real_fetch, real_post
    end)

    local function stub_fetch(body, err)
        page.fetch = function(url, cb)
            fetched[#fetched + 1] = url
            cb(body, err)
        end
    end
    local function stub_post(res, err)
        api_utils.post = function(endpoint, opts)
            posted[#posted + 1] = endpoint
            opts.callback(res, err)
        end
    end

    it("fetches the train page for the language being trained, not python", function()
        stub_fetch('<script>"/projects/aaaaaaaaaaaaaaaaaaaaaaaa/haskell/session"</script>')
        stub_post({ solutionId = "s1" })
        local got
        train.start("kid", "haskell", function(s) got = s end)
        assert.truthy(fetched[1]:find("/kata/kid/train/haskell", 1, true))
        assert.are.equal("/kata/projects/aaaaaaaaaaaaaaaaaaaaaaaa/haskell/session", posted[1])
        assert.are.equal("aaaaaaaaaaaaaaaaaaaaaaaa", got.projectId)
    end)

    it("passes an auth error through with its flag, so the caller can drop the cached session", function()
        stub_fetch(nil, page.status_err(403))
        local err
        train.start("kid", "python", function(_, e) err = e end)
        assert.is_true(err.auth)
    end)

    it("passes rate limiting through as rate_limited, not as 'are your cookies valid'", function()
        stub_fetch(nil, page.status_err(429, "30"))
        local err
        train.start("kid", "python", function(_, e) err = e end)
        assert.is_true(err.rate_limited)
        assert.is_nil(err.msg:find("cookies", 1, true))
    end)

    it("reports a transport failure through the callback instead of raising", function()
        stub_fetch(nil, { msg = "curl error", curl = true })
        local err
        train.start("kid", "python", function(_, e) err = e end)
        assert.is_not_nil(err)
        assert.truthy(err.msg:find("train page", 1, true))
    end)

    it("names the language when the page has no project id", function()
        stub_fetch("<html>no project here</html>")
        local err
        train.start("kid", "ruby", function(_, e) err = e end)
        assert.truthy(err.msg:find("ruby", 1, true))
        assert.are.equal(0, #posted)
    end)

    it("does not index a non-JSON 2xx session body", function()
        stub_fetch('"/projects/aaaaaaaaaaaaaaaaaaaaaaaa/"')
        stub_post("<html>login</html>")
        local got, err
        train.start("kid", "python", function(s, e) got, err = s, e end)
        assert.is_nil(got)
        assert.truthy(err.msg:find("training session", 1, true))
    end)
end)
