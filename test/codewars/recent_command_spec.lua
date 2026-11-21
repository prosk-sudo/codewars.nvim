-- :CW recent: straight back into the kata you opened last, in the language
-- you last used. The list of everything you started is :CW unfinished.
describe(":CW recent", function()
    local saved = {}
    local STUBBED = { "codewars.cache.recent", "codewars-ui.kata", "codewars.logger" }
    local history, mounted, said, cmd, utils, real_dup

    before_each(function()
        for _, m in ipairs(STUBBED) do saved[m] = package.loaded[m] end
        history, mounted, said = {}, {}, {}
        package.loaded["codewars.cache.recent"] = { get = function() return history end }
        package.loaded["codewars-ui.kata"] = {
            new = function(_, slug, lang)
                return { mount = function() mounted[#mounted + 1] = { slug = slug, lang = lang } end }
            end,
        }
        package.loaded["codewars.logger"] = setmetatable({}, {
            __index = function(_, level)
                return function(m) said[#said + 1] = { level = level, msg = tostring(m) } end
            end,
        })
        package.loaded["codewars.command"] = nil
        cmd = require("codewars.command")
        utils = require("codewars.utils")
        real_dup = utils.detect_duplicate_kata
    end)

    after_each(function()
        utils.detect_duplicate_kata = real_dup
        for _, m in ipairs(STUBBED) do package.loaded[m] = saved[m] end
        package.loaded["codewars.command"] = nil
        vim.cmd("silent! tabonly")
    end)

    it("reopens the kata you opened last, in the language you last used", function()
        history = {
            { slug = "fake-binary", lang = "rust", opened_at = os.time() },
            { slug = "multiply", lang = "python", opened_at = os.time() - 60 },
        }
        cmd.recent()
        assert.are.same({ { slug = "fake-binary", lang = "rust" } }, mounted)
    end)

    it("brings its tab forward when it is still open, without fetching it again", function()
        history = { { slug = "fake-binary", lang = "rust", opened_at = os.time() } }
        vim.cmd("tabnew")
        local tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabfirst")
        utils.detect_duplicate_kata = function(slug, lang)
            if slug == "fake-binary" and lang == "rust" then return tab end
        end
        cmd.recent()
        assert.are.equal(tab, vim.api.nvim_get_current_tabpage())
        assert.are.same({}, mounted)
    end)

    it("says so when you have not opened a kata yet", function()
        cmd.recent()
        assert.are.same({}, mounted)
        local msg = said[#said] and said[#said].msg or ""
        assert.truthy(msg:find("No recent kata", 1, true), msg)
    end)

    it("is described in :CW help as reopening the last kata", function()
        local row
        for _, line in ipairs((cmd._help_lines())) do
            if line:find(":CW recent ", 1, true) then row = line end
        end
        assert.is_not_nil(row, "no recent row in :CW help")
        assert.truthy(row:find("opened last", 1, true), row)
    end)
end)
