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

--- The buffer-local normal-mode mapping of `key` in the code buffer, if any.
local function buffer_map(ws, key)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(ws.bufnr, "n")) do
        if map.lhs == key then
            return map
        end
    end
end

--- A mapping that belongs to the user, e.g. from their FileType autocmd.
local function map_as_user(ws, key)
    vim.keymap.set("n", key, "<Nop>", { buffer = ws.bufnr, desc = "user's own" })
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

describe("Kumite read-only guard only removes its own mappings", function()
    local real_api, real_confirm, real_publish

    before_each(function()
        real_api = package.loaded["codewars.api.kumite"]
        real_confirm = package.loaded["codewars-ui.popup.confirm"]
        real_publish = package.loaded["codewars.kumite.publish"]
        package.loaded["codewars-ui.popup.confirm"] = {
            open = function(_, done)
                done(true)
            end,
        }
    end)

    after_each(function()
        package.loaded["codewars.api.kumite"] = real_api
        package.loaded["codewars-ui.popup.confirm"] = real_confirm
        package.loaded["codewars.kumite.publish"] = real_publish
        vim.cmd("silent! tabonly!")
    end)

    local function stub_save(res, err)
        package.loaded["codewars.api.kumite"] = {
            is_server_id = function(id)
                return type(id) == "string" and #id == 24 and id:match("^%x+$") ~= nil
            end,
            default_version = function()
                return "3.8"
            end,
            save_draft = function(_, _, done)
                done(res, err)
            end,
            unpublish = function(_, done)
                done(nil)
            end,
        }
    end

    it("keeps a user's mapping through the first save of an editable kumite", function()
        -- A FileType autocmd maps keys in a new buffer; a guard that was never
        -- installed here has nothing of its own to remove.
        stub_save({ id = "6a63e7e085269ff93dc63388" }, nil)
        local ws = mount("local_fork")
        map_as_user(ws, "s")

        ws:save()

        assert.are.equal("server_draft", ws.state)
        assert.are.equal("user's own", (buffer_map(ws, "s") or {}).desc)
    end)

    it("keeps a user's mapping when a save fails and the state is restored", function()
        stub_save(nil, { msg = "boom" })
        local ws = mount("local_fork")
        map_as_user(ws, "s")

        ws:save()

        assert.are.equal("local_fork", ws.state)
        assert.are.equal("user's own", (buffer_map(ws, "s") or {}).desc)
    end)

    it("keeps a user's mapping when a publish fails and the state is restored", function()
        stub_save(nil, nil)
        package.loaded["codewars.kumite.publish"] = {
            run_and_publish = function(_, done)
                done(nil, { msg = "tests failed" })
            end,
        }
        local ws = mount("server_draft")
        map_as_user(ws, "q")

        ws:publish()

        assert.are.equal("server_draft", ws.state)
        assert.are.equal("user's own", (buffer_map(ws, "q") or {}).desc)
    end)

    it("keeps a mapping the user put over the guard once the kumite is editable", function()
        stub_save(nil, nil)
        local ws = mount("published")
        map_as_user(ws, "s") -- replaces the guard's own `s`

        ws:unpublish()

        assert.are.equal("user's own", (buffer_map(ws, "s") or {}).desc)
        assert.is_nil(buffer_map(ws, "i"), "the guard's other keys must still go")
    end)
end)
