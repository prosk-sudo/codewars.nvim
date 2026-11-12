local log = require("codewars.logger")

---@class cw.picker.DropdownEntry
---@field label string display text (searchable)
---@field value any passed to on_select; wrap in a table if nil is meaningful
---@field icon string? optional left icon (enables the 2-column layout)
---@field icon_hl string? highlight group for the icon
---@field ordinal string? custom search text (defaults to label)

---@class cw.picker.DropdownOpts
---@field prompt_title string
---@field entries cw.picker.DropdownEntry[]
---@field default_idx integer? 1-based initial selection
---@field width integer? dropdown width (default 40)
---@field height integer? dropdown height (default min(#entries + 4, 25))
---@field on_select fun(value: any) called with entry.value on <CR>

---@class cw.picker.Dropdown
local M = {}

local _telescope = nil
local function require_telescope()
    if _telescope then return _telescope end

    local ok, pickers = pcall(require, "telescope.pickers")
    if not ok then
        log.error("telescope.nvim is required for the picker")
        return nil
    end

    _telescope = {
        pickers = pickers,
        finders = require("telescope.finders"),
        conf = require("telescope.config").values,
        actions = require("telescope.actions"),
        action_state = require("telescope.actions.state"),
        entry_display = require("telescope.pickers.entry_display"),
        themes = require("telescope.themes"),
    }
    return _telescope
end

local _provider = nil

--- Test seam: allows specs to reset the memoized telescope table and provider.
function M._reset()
    _telescope = nil
    _provider = nil
end

--- Resolved picker backend. `picker.provider` wins; unset means telescope
--- when it is installed, else vim.ui.select, so the user's global picker
--- (fzf-lua, snacks, dressing, telescope-ui-select) is used.
---@return "telescope"|"select"
function M.provider()
    if _provider then return _provider end
    local user = require("codewars.config").user or {}
    local wanted = (user.picker or {}).provider
    if wanted then
        _provider = wanted
    else
        _provider = pcall(require, "telescope") and "telescope" or "select"
    end
    return _provider
end

---@param item cw.picker.DropdownEntry
---@return string
local function select_label(item)
    if item.icon and item.icon ~= "" then
        return item.icon .. " " .. item.label
    end
    return item.label
end

--- vim.ui.select has no preselection or sizing: default_idx, width and
--- height are telescope-only. A cancelled select (nil choice) is a no-op.
---@param opts cw.picker.DropdownOpts
local function open_select(opts)
    vim.ui.select(opts.entries or {}, {
        prompt = opts.prompt_title,
        format_item = select_label,
    }, function(choice)
        if choice and opts.on_select then
            opts.on_select(choice.value)
        end
    end)
end

--- Shared accessor so other picker modules reuse the same memoized
--- telescope table (single copy of the missing-telescope error path).
---@return table?
function M.telescope()
    return require_telescope()
end

--- Open a single-select dropdown (telescope or vim.ui.select).
--- Selecting an entry closes the dropdown and calls on_select(entry.value).
--- <CR> with no matching entry is a no-op (dropdown stays open).
---@param opts cw.picker.DropdownOpts
function M.open(opts)
    if M.provider() == "select" then
        return open_select(opts)
    end
    local t = require_telescope()
    if not t then return end

    local entries = opts.entries or {}

    local has_icons = false
    for _, e in ipairs(entries) do
        if e.icon then
            has_icons = true
            break
        end
    end

    local displayer
    if has_icons then
        displayer = t.entry_display.create({
            separator = " ",
            items = { { width = 2 }, { remaining = true } },
        })
    end

    local function entry_maker(item)
        return {
            value = item,
            display = function()
                if has_icons then
                    return displayer({
                        { item.icon or "", item.icon_hl or "codewars_normal" },
                        { item.label },
                    })
                end
                return item.label
            end,
            ordinal = item.ordinal or item.label,
        }
    end

    local topts = t.themes.get_dropdown({
        layout_config = {
            width = opts.width or 40,
            height = opts.height or math.min(#entries + 4, 25),
        },
    })

    t.pickers.new(topts, {
        prompt_title = opts.prompt_title,
        default_selection_index = opts.default_idx,
        finder = t.finders.new_table({
            results = entries,
            entry_maker = entry_maker,
        }),
        sorter = t.conf.generic_sorter(topts),
        attach_mappings = function(prompt_bufnr)
            t.actions.select_default:replace(function()
                local sel = t.action_state.get_selected_entry()
                if not sel then return end
                t.actions.close(prompt_bufnr)
                if opts.on_select then
                    opts.on_select(sel.value.value)
                end
            end)
            return true
        end,
    }):find()
end

return M
