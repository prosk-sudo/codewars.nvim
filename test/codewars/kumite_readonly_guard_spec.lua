local Kumite = require("codewars-ui.kumite")

local GUARDED_KEYS = { "i", "I", "a", "A", "o", "O", "c", "C", "s", "S", "R", "q" }

-- A fresh id per workspace: mount() focuses an open workspace for the same
-- snippet instead of building another.
local mounted = 0

--- A really-mounted workspace, because the guard is a set of buffer-local
--- keymaps and only a real buffer can say whether they are still there.
local function mount(state)
    mounted = mounted + 1
    local ws = Kumite:new({
        id = ("6a63e7e085269ff93dc633%02d"):format(mounted),
        title = "musti",
        description = "",
        language = "python",
        code = "print(1)",
        fixture = "test",
        ["package"] = "",
        test_framework = "cw-2",
        state = "published",
    }, { state = state })
    ws:mount()
    return ws
end

--- The guard keys currently mapped in the code buffer.
local function guarded(ws)
    local present = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(ws.bufnr, "n")) do
        present[map.lhs] = true
    end
    return vim.tbl_filter(function(key)
        return present[key]
    end, GUARDED_KEYS)
end

describe("Kumite read-only guard follows the state", function()
    local real_api, real_confirm

    before_each(function()
        real_api = package.loaded["codewars.api.kumite"]
        real_confirm = package.loaded["codewars-ui.popup.confirm"]
        -- Both server calls succeed at once, and the convert confirmation is
        -- answered "yes", so the whole transition runs synchronously.
        package.loaded["codewars.api.kumite"] = {
            is_server_id = function(id)
                return type(id) == "string" and #id == 24 and id:match("^%x+$") ~= nil
            end,
            unpublish = function(_, done)
                done(nil)
            end,
            convert_to_kata = function(_, done)
                done("/kata/5a2b3c4d5e6f708192a3b4c5/edit", nil)
            end,
        }
        package.loaded["codewars-ui.popup.confirm"] = {
            open = function(_, done)
                done(true)
            end,
        }
    end)

    after_each(function()
        package.loaded["codewars.api.kumite"] = real_api
        package.loaded["codewars-ui.popup.confirm"] = real_confirm
        vim.cmd("silent! tabonly!")
    end)

    it("guards the insert keys while the kumite is published", function()
        -- Precondition for the specs below: without it, "the guard is gone"
        -- would also pass on a workspace that never had one.
        local ws = mount("published")
        assert.same(GUARDED_KEYS, guarded(ws))
        assert.is_false(vim.bo[ws.bufnr].modifiable)
    end)

    it("lifts the guard when unpublish makes the kumite an editable draft", function()
        local ws = mount("published")

        ws:unpublish()

        assert.are.equal("server_draft", ws.state)
        assert.is_true(vim.bo[ws.bufnr].modifiable)
        assert.same({}, guarded(ws))
    end)

    it("lifts the guard when convert makes the kumite an editable draft", function()
        local ws = mount("published")

        ws:convert()

        assert.are.equal("server_draft", ws.state)
        assert.is_true(vim.bo[ws.bufnr].modifiable)
        assert.same({}, guarded(ws))
    end)

    it("puts the guard back when the draft is published again", function()
        local ws = mount("published")
        ws:unpublish()

        ws:set_state("published")

        assert.is_false(vim.bo[ws.bufnr].modifiable)
        assert.same(GUARDED_KEYS, guarded(ws))
    end)

    it("still lifts the guard when a read-only view is forked", function()
        local ws = mount("published_view")
        assert.same(GUARDED_KEYS, guarded(ws))

        ws:fork()

        assert.are.equal("local_fork", ws.state)
        assert.is_true(vim.bo[ws.bufnr].modifiable)
        assert.same({}, guarded(ws))
    end)

    it("leaves the user's own global mappings alone on an unmounted workspace", function()
        -- With no buffer, keymap.del would fall back to GLOBAL mappings --
        -- `s` and `S` are what leap and flash bind.
        vim.keymap.set("n", "s", "<Nop>")
        local ws = Kumite:new({
            id = "6a63e7e085269ff93dc63399", title = "t", description = "", language = "python",
            code = "x", fixture = "", ["package"] = "", test_framework = "cw-2", state = "draft",
        }, { state = "published" })

        ws:set_state("server_draft")

        local survived = vim.fn.maparg("s", "n") ~= ""
        pcall(vim.keymap.del, "n", "s")
        assert.is_true(survived)
    end)
end)
