local template = require("codewars.config.template")
local P = require("plenary.path")

_Cw_state = {
    menu = nil, ---@type cw.ui.Menu?
    katas = {}, ---@type cw.ui.Kata[]
}

---@class cw.Config
local config = {
    default = template,
    user = template,

    name = "codewars.nvim",
    debug = false,
    lang = "python",
    lang_persisted = false,
    storage = {}, ---@type table<string, Path>

    langs = require("codewars.config.langs"),
}

---@param cfg cw.UserConfig
function config.apply(cfg)
    config.user = vim.tbl_deep_extend("force", config.default, cfg or {})
end

function config.setup()
    config.validate()

    config.user.storage = vim.tbl_map(vim.fn.expand, config.user.storage)

    config.debug = config.user.debug or false
    config.lang = config.user.lang

    config.storage.home = P:new(config.user.storage.home)
    config.storage.home:mkdir({ parents = true })

    config.storage.cache = P:new(config.user.storage.cache)
    config.storage.cache:mkdir({ parents = true })

    -- Load persisted default language (overrides config if set)
    local lang_file = config.storage.cache:joinpath("default_lang")
    if lang_file:exists() then
        local ok, contents = pcall(function() return lang_file:read() end)
        if ok and contents then
            local saved_lang = contents:match("^%s*(.-)%s*$")
            if saved_lang and saved_lang ~= "" then
                local utils = require("codewars.utils")
                if utils.get_lang(saved_lang) then
                    config.lang = saved_lang
                    config.lang_persisted = true
                end
            end
        end
    end
end

--- Persist the default language to disk.
---@param lang string
function config.save_lang(lang)
    local lang_file = config.storage.cache:joinpath("default_lang")
    pcall(function() lang_file:write(lang, "w") end)
    config.lang = lang
    config.user.lang = lang
    config.lang_persisted = true
end

function config.validate()
    assert(vim.fn.has("nvim-0.9.0") == 1, "Neovim >= 0.9.0 required")

    local utils = require("codewars.utils")
    if not utils.get_lang(config.lang) then
        local lang_slugs = vim.tbl_map(function(lang)
            return lang.slug
        end, config.langs)

        local matches = {}
        for _, slug in ipairs(lang_slugs) do
            if slug:find(config.lang, 1, true) or config.lang:find(slug, 1, true) then
                table.insert(matches, slug)
            end
        end

        if not vim.tbl_isempty(matches) then
            local log = require("codewars.logger")
            log.warn("Did you mean: { " .. table.concat(matches, ", ") .. " }?")
        end

        error("Unsupported Language: " .. config.lang)
    end
end

return config
