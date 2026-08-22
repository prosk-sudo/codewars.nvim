local config = require("codewars.config")
local ui_utils = require("codewars-ui.utils")
local log = require("codewars.logger")
local cookie_cache = require("codewars.cache.cookie")
local api = vim.api

local ascii = {
    [[  $$$$$$\                  $$\                                                        ]],
    [[ $$  __$$\                 $$ |                                                       ]],
    [[ $$ /  \__| $$$$$$\   $$$$$$$ | $$$$$$\  $$\  $$\  $$\  $$$$$$\   $$$$$$\   $$$$$$$\  ]],
    [[ $$ |      $$  __$$\ $$  __$$ |$$  __$$\ $$ | $$ | $$ | \____$$\ $$  __$$\ $$  _____| ]],
    [[ $$ |      $$ /  $$ |$$ /  $$ |$$$$$$$$ |$$ | $$ | $$ | $$$$$$$ |$$ |  \__|\_$$$$$$\  ]],
    [[ $$ |  $$\ $$ |  $$ |$$ |  $$ |$$   ____|$$ | $$ | $$ |$$  __$$ |$$ |       \____$$ | ]],
    [[ \$$$$$$  |\$$$$$$  |\$$$$$$$ |\$$$$$$$\ \$$$$$\$$$$  |\$$$$$$$ |$$ |      $$$$$$$  | ]],
    [[  \______/  \______/  \_______| \_______| \_____\____/  \_______|\__|      \_______/  ]],
}

---@class cw.ui.Menu
---@field bufnr integer?
---@field winid integer?
---@field buttons table<integer, { label: string, fn: function }>
---@field cursor_idx integer
---@field page string
---@field pages table<string, table[]>
local Menu = {}
Menu.__index = Menu

-- Page definitions: each page is a list of buttons (I is resolved at init time)
local I = {}

--- Fetch user data and call cb when done.
--- If username is not configured, auto-detect from dashboard first.
local function fetch_user_data(menu, cb)
    local user_api = require("codewars.api.user")

    local function fetch_by_username(username)
        user_api.get(username, function(data, err)
            if not err and data then
                menu._user_data = data
            end
            if cb then vim.schedule(cb) end
        end)
    end

    if config.user.username ~= "" then
        fetch_by_username(config.user.username)
    else
        -- Auto-detect username from dashboard
        user_api.get_current(function(profile, err)
            if not err and profile and profile.username then
                config.user.username = profile.username
                -- Auto-detect preferred language only if user hasn't explicitly set one
                if not config.lang_persisted and profile.current_language and profile.current_language ~= "" then
                    config.lang = profile.current_language
                    config.user.lang = profile.current_language
                end
                fetch_by_username(profile.username)
            else
                -- Swallowing this left a menu that looks signed in, has no
                -- username, and explains nothing -- while every feature
                -- needing an identity failed separately.
                if err then
                    log.warn(("Signed in, but could not detect your username: %s")
                        :format(err.msg or "unknown error"))
                end
                if cb then vim.schedule(cb) end
            end
        end)
    end
end

local function build_pages(menu)
    I = require("codewars.icons").get()

    local function leaderboard_show(category_key)
        return function()
            require("codewars.command").leaderboard({ _positional = { category_key } })
        end
    end

    local function signin_fn()
        require("codewars.command").cookie_prompt(function(success)
            if success then
                fetch_user_data(menu, function()
                    menu:set_page("main")
                end)
            end
        end)
    end

    return {
        signin = {
            { icon = I.signin,  label = "Sign In (Cookie)", sc = "i", fn = signin_fn },
            { icon = I.exit,    label = "Exit",             sc = "qa", fn = function()
                require("codewars").stop()
            end },
        },

        main = {
            { icon = I.katas,   label = "Katas",       sc = "k", expandable = true, fn = function()
                menu:set_page("katas")
            end },
            { icon = I.kumite,  label = "Kumite",      sc = "m", expandable = true, fn = function()
                menu:set_page("kumite")
            end },
            { icon = I.stats,   label = "Statistics",  sc = "s", fn = function()
                require("codewars.command").stats({})
            end },
            { icon = I.leaderboard, label = "Leaderboard", sc = "l", expandable = true, fn = function()
                menu:set_page("leaderboard")
            end },
            { icon = I.cookie,  label = "Cookie",      sc = "i", expandable = true, fn = function()
                menu:set_page("cookie")
            end },
            { icon = I.cache,   label = "Cache",       sc = "c", expandable = true, fn = function()
                menu:set_page("cache")
            end },
            { icon = I.exit,    label = "Exit",        sc = "qa", fn = function()
                require("codewars").stop()
            end },
        },

        katas = {
            { icon = I.search,  label = "Train",       sc = "t", fn = function()
                vim.ui.input({ prompt = "Kata title, slug or URL: " }, function(input)
                    if input and input ~= "" then
                        local utils = require("codewars.utils")
                        local slug = utils.parse_slug(input)
                        local Kata = require("codewars-ui.kata")
                        utils.auth_guard()
                        Kata:new(slug):mount()
                    end
                end)
            end },
            { icon = I.list,    label = "List",        sc = "l", fn = function()
                require("codewars.command").list({})
            end },
            { icon = I.focus,   label = "Choose Today's Focus", sc = "f", fn = function()
                require("codewars.command").focus({})
            end },
            { icon = I.back,    label = "Back",        sc = "b", fn = function()
                menu:set_page("main")
            end },
        },

        leaderboard = {
            { icon = I.leaderboard,          label = "Overall",                      sc = "o", fn = leaderboard_show("overall") },
            { icon = I.completed,            label = "Completed Kata",               sc = "k", fn = leaderboard_show("kata") },
            { icon = I.leaderboard_authored, label = "Authored Kata & Translations", sc = "a", fn = leaderboard_show("authored") },
            { icon = I.focus_rank_up,        label = "Ranks",                        sc = "r", fn = leaderboard_show("ranks") },
            { icon = I.back,                 label = "Back",                         sc = "b", fn = function()
                menu:set_page("main")
            end },
        },

        -- Browse + New ship now; My Drafts mounts with P3's drafts registry.
        kumite = {
            { icon = I.kumite,  label = "Browse",      sc = "l", fn = function()
                require("codewars.command").kumite()
            end },
            { icon = I.search,  label = "New",         sc = "n", fn = function()
                require("codewars.command").kumite_new({})
            end },
            { icon = I.back,    label = "Back",        sc = "b", fn = function()
                menu:set_page("main")
            end },
        },

        cookie = {
            { icon = I.update,  label = "Update",      sc = "u", fn = signin_fn },
            { icon = I.signout, label = "Delete / Sign Out",    sc = "d", fn = function()
                require("codewars.command").sign_out()
                menu._user_data = nil
                menu:set_page("signin")
            end },
            { icon = I.back,    label = "Back",        sc = "b", fn = function()
                menu:set_page("main")
            end },
        },

        cache = {
            { icon = I.update,  label = "Update",      sc = "u", fn = function()
                require("codewars.command").cache_update()
            end },
            { icon = I.back,    label = "Back",        sc = "b", fn = function()
                menu:set_page("main")
            end },
        },
    }
end

-- Page titles (breadcrumb style for sub-pages)
local page_titles = {
    signin = { { "Sign In", "Title" } },
    main = { { "Menu", "Title" } },
    katas = { { "Menu", "codewars_breadcrumb" }, { " > ", "codewars_icon" }, { "Katas", "Title" } },
    leaderboard = { { "Menu", "codewars_breadcrumb" }, { " > ", "codewars_icon" }, { "Leaderboard", "Title" } },
    kumite = { { "Menu", "codewars_breadcrumb" }, { " > ", "codewars_icon" }, { "Kumite", "Title" } },
    cookie = { { "Menu", "codewars_breadcrumb" }, { " > ", "codewars_icon" }, { "Cookie", "Title" } },
    cache = { { "Menu", "codewars_breadcrumb" }, { " > ", "codewars_icon" }, { "Cache", "Title" } },
}

function Menu:set_page(name)
    self.page = name
    self.cursor_idx = 1
    self:draw()
    self:set_keymaps()
end

function Menu:mount()
    self.bufnr = api.nvim_get_current_buf()
    self.winid = api.nvim_get_current_win()

    api.nvim_buf_set_name(self.bufnr, "")

    ui_utils.buf_set_opts(self.bufnr, {
        modifiable = false,
        buflisted = false,
        matchpairs = "",
        swapfile = false,
        buftype = "nofile",
        filetype = "codewars",
        synmaxcol = 0,
    })
    ui_utils.win_set_opts(self.winid, {
        wrap = false,
        colorcolumn = "",
        foldlevel = 999,
        foldcolumn = "0",
        cursorcolumn = false,
        cursorline = false,
        number = false,
        relativenumber = false,
        list = false,
        spell = false,
        signcolumn = "no",
    })

    if vim.fn.has("nvim-0.10.0") == 1 then
        ui_utils.win_set_opts(self.winid, { winfixbuf = true })
    end

    self:autocmds()

    if cookie_cache.get() then
        self:set_page("main")
        fetch_user_data(self, function()
            self._redraw_only = true
            self:draw()
        end)
    else
        self:set_page("signin")
    end
end

function Menu:remount()
    if self.winid and api.nvim_win_is_valid(self.winid) then
        api.nvim_win_close(self.winid, true)
    end
    if self.bufnr and api.nvim_buf_is_valid(self.bufnr) then
        api.nvim_buf_delete(self.bufnr, { force = true })
    end

    vim.cmd("0tabnew")
    self.bufnr = api.nvim_get_current_buf()
    self.winid = api.nvim_get_current_win()
    self:mount()
end

function Menu:draw()
    if not self.bufnr or not api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    local win_width = 80
    local win_height = 0
    if self.winid and api.nvim_win_is_valid(self.winid) then
        win_width = api.nvim_win_get_width(self.winid)
        win_height = api.nvim_win_get_height(self.winid)
    end

    local lines = {}
    self.buttons = {}
    self._line_hls = {}

    local function center_pad(text, block_width)
        local w = block_width or vim.fn.strdisplaywidth(text)
        local pad = math.max(0, math.floor((win_width - w) / 2))
        return string.rep(" ", pad) .. text, pad
    end

    local function center(text, block_width)
        return (center_pad(text, block_width))
    end

    local header_width = 0
    for _, line in ipairs(ascii) do
        local w = vim.fn.strdisplaywidth(line)
        if w > header_width then header_width = w end
    end

    -- Top padding is applied AFTER the block is built, once its real height
    -- is known — see the centering step before buf_set_lines.
    local header_start = #lines
    for _, line in ipairs(ascii) do
        table.insert(lines, center(line, header_width))
    end

    table.insert(lines, "")
    table.insert(lines, "")

    local BTN_WIDTH = 50
    local title_parts = page_titles[self.page] or { { self.page, "Title" } }
    local title_text = ""
    for _, part in ipairs(title_parts) do
        title_text = title_text .. part[1]
    end
    local centered_title, title_pad = center_pad(title_text)
    local title_row = #lines
    table.insert(lines, centered_title)

    self._line_hls[title_row] = {}
    local col = title_pad
    for _, part in ipairs(title_parts) do
        local part_len = #part[1]
        table.insert(self._line_hls[title_row], { col, col + part_len, part[2] })
        col = col + part_len
    end

    table.insert(lines, "")

    -- Buttons (spacing between buttons, not after last — matches leetcode.nvim)
    local expand_arrow = I.expand
    local current_buttons = self.pages[self.page] or {}
    for i, btn in ipairs(current_buttons) do
        local left = btn.icon .. " " .. btn.label
        if btn.expandable then
            left = left .. " " .. expand_arrow
        end

        local sc_text = btn.sc
        local left_w = vim.api.nvim_strwidth(left)
        local sc_w = vim.api.nvim_strwidth(sc_text)
        local pad = math.max(1, BTN_WIDTH - left_w - sc_w)

        local full_btn = left .. string.rep(" ", pad) .. sc_text
        local centered_btn, btn_pad = center_pad(full_btn, BTN_WIDTH)

        local row = #lines
        table.insert(lines, centered_btn)
        if i < #current_buttons then
            table.insert(lines, "")
        end

        local icon_byte_len = #btn.icon
        local sc_byte_start = #centered_btn - #sc_text
        local hls = {
            { btn_pad, btn_pad + icon_byte_len, "codewars_icon" },
            { sc_byte_start, #centered_btn, "codewars_shortcut" },
        }
        if btn.expandable then
            local arrow_byte_start = btn_pad + #btn.icon + 1 + #btn.label + 1
            local arrow_byte_end = arrow_byte_start + #expand_arrow
            table.insert(hls, { arrow_byte_start, arrow_byte_end, "codewars_breadcrumb" })
        end
        self._line_hls[row] = hls
        self.buttons[row + 1] = btn
    end

    local signed_in = cookie_cache.get() ~= nil

    table.insert(lines, "")
    table.insert(lines, "")
    table.insert(lines, "")

    local honor_row = nil
    local username = config.user.username
    if username ~= "" then
        local cached_data = self._user_data
        if cached_data then
            local rank_name = ""
            if cached_data.ranks and cached_data.ranks.overall then
                rank_name = cached_data.ranks.overall.name or ""
            end
            local honor = cached_data.honor or 0
            local completed = 0
            if cached_data.codeChallenges then
                completed = cached_data.codeChallenges.totalCompleted or 0
            end
            local info_line = rank_name .. "  |  " .. honor .. " honor  |  " .. completed .. " kata completed"
            honor_row = #lines
            table.insert(lines, center(info_line))
            table.insert(lines, "")
        end
    end

    local signin_row = #lines
    if signed_in and username ~= "" then
        table.insert(lines, center("Signed in as: " .. username))
    elseif signed_in then
        table.insert(lines, center("Signed in"))
    else
        table.insert(lines, center("codewars.com"))
    end

    -- Vertically centre the block.
    --
    -- This used to be a fixed 4-line pad plus a `zz` at the end. `zz` only
    -- repositions by scrolling, so on a window TALLER than the block there
    -- is nothing to scroll and it does nothing: the menu sat at the top with
    -- all the slack dumped below it, and the gap grew on pages with fewer
    -- buttons. Pad from the real window height instead, and leave `zz` to
    -- handle the opposite case, where the block overflows a short window.
    --
    -- TOP_PAD_MIN is a FLOOR: the centred pad is never allowed below it, so
    -- the block moves monotonically as the window grows. Taking the centred
    -- value whenever the block merely fit let a window a few rows taller
    -- than the block pad 2 where the one-row-shorter window padded 4, and
    -- the menu jumped upward on resize.
    local TOP_PAD_MIN = 4
    local top_pad = TOP_PAD_MIN
    if win_height > 0 then
        top_pad = math.max(TOP_PAD_MIN, math.floor((win_height - #lines) / 2))
    end

    if top_pad > 0 then
        local padded = {}
        for _ = 1, top_pad do
            table.insert(padded, "")
        end
        vim.list_extend(padded, lines)
        lines = padded

        -- Every recorded row index was captured against the unpadded block,
        -- so shift them all or the highlights and keymaps land on the wrong
        -- lines.
        local function shift(t)
            local out = {}
            for row, v in pairs(t) do out[row + top_pad] = v end
            return out
        end
        self._line_hls = shift(self._line_hls)
        self.buttons = shift(self.buttons)
        header_start = header_start + top_pad
        signin_row = signin_row + top_pad
        if honor_row then honor_row = honor_row + top_pad end
    end

    local content_height = #lines

    ui_utils.buf_set_lines(self.bufnr, lines)

    local ns = self._ns
    api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)

    for i = header_start, header_start + #ascii - 1 do
        api.nvim_buf_add_highlight(self.bufnr, ns, "codewars_header", i, 0, -1)
    end

    for row, segments in pairs(self._line_hls or {}) do
        for _, seg in ipairs(segments) do
            api.nvim_buf_add_highlight(self.bufnr, ns, seg[3], row, seg[1], seg[2])
        end
    end

    if honor_row then
        api.nvim_buf_add_highlight(self.bufnr, ns, "codewars_ref", honor_row, 0, -1)
    end

    if signed_in and username ~= "" then
        local signin_line = lines[signin_row + 1] or ""
        api.nvim_buf_add_highlight(self.bufnr, ns, "Comment", signin_row, 0, -1)
        local uname_start = signin_line:find(username, 1, true)
        if uname_start then
            api.nvim_buf_add_highlight(self.bufnr, ns, "codewars_warning", signin_row, uname_start - 1, -1)
        end
    elseif signed_in then
        api.nvim_buf_add_highlight(self.bufnr, ns, "Comment", signin_row, 0, -1)
    else
        api.nvim_buf_add_highlight(self.bufnr, ns, "codewars_warning", signin_row, 0, -1)
    end

    local rows = self:get_button_rows()
    if #rows > 0 then
        if not self._redraw_only then
            self.cursor_idx = 1
        end
        self.cursor_idx = math.min(self.cursor_idx, #rows)
        self:_jump_to_row(rows[self.cursor_idx])

        -- Only when the block overflows a short window: there `zz` genuinely
        -- keeps the footer on screen. When it fits, the padding above has
        -- already placed it and scrolling would undo that.
        if self.winid and api.nvim_win_is_valid(self.winid)
            and win_height > 0 and content_height > win_height
        then
            api.nvim_win_call(self.winid, function()
                vim.cmd("normal! zz")
            end)
        end
    end
    self._redraw_only = false
end

function Menu:get_button_rows()
    local rows = vim.tbl_keys(self.buttons)
    table.sort(rows)
    return rows
end

function Menu:_jump_to_row(row)
    local line = vim.fn.getline(row)
    local col = #(line:match("^(%s*)") or "")
    pcall(api.nvim_win_set_cursor, self.winid, { row, col })
end

function Menu:cursor_move()
    if not self.winid or not api.nvim_win_is_valid(self.winid) then
        return
    end

    local rows = self:get_button_rows()
    if #rows == 0 then return end

    local curr = api.nvim_win_get_cursor(self.winid)[1]

    local nearest_idx = 1
    local min_dist = math.huge
    for i, row in ipairs(rows) do
        local dist = math.abs(row - curr)
        if dist < min_dist then
            min_dist = dist
            nearest_idx = i
        end
    end

    self.cursor_idx = nearest_idx
    self:_jump_to_row(rows[nearest_idx])
end

function Menu:press()
    if not self.winid or not api.nvim_win_is_valid(self.winid) then
        return
    end

    local row = api.nvim_win_get_cursor(self.winid)[1]
    local btn = self.buttons[row]
    if btn and btn.fn then
        local ok, err = pcall(btn.fn)
        if not ok then
            log.error(err)
        end
    end
end

function Menu:autocmds()
    local group_id = api.nvim_create_augroup("codewars_menu", { clear = true })

    -- Deliberately NOT buffer-local. WinResized fires once per tab with
    -- <abuf> bound to the current buffer, so a buffer-local autocmd never
    -- fires when the menu's window is resized from a neighbouring split
    -- (dragging the separator from the other side). Listen globally and let
    -- the dimension comparison below discard events that did not touch us.
    api.nvim_create_autocmd("WinResized", {
        group = group_id,
        callback = function()
            local valid = self.winid and api.nvim_win_is_valid(self.winid)
            if not valid then return end
            local w = valid and api.nvim_win_get_width(self.winid) or 0
            -- Height matters now that the block is centred vertically: a
            -- height-only resize used to skip the redraw and leave the menu
            -- centred for the OLD height.
            local h = valid and api.nvim_win_get_height(self.winid) or 0
            if w == self._last_width and h == self._last_height then return end
            self._last_width = w
            self._last_height = h
            self._redraw_only = true
            self:draw()
        end,
    })

    api.nvim_create_autocmd("CursorMoved", {
        group = group_id,
        buffer = self.bufnr,
        callback = function()
            self:cursor_move()
        end,
    })

    api.nvim_create_autocmd("QuitPre", {
        group = group_id,
        buffer = self.bufnr,
        callback = function()
            if vim.fn.argc(-1) == 1 and vim.fn.argv(0, -1) == config.user.arg then
                local codewars = require("codewars")
                codewars.stop()
            end
        end,
    })
end

function Menu:set_keymaps()
    if not self.bufnr or not api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    local existing = api.nvim_buf_get_keymap(self.bufnr, "n")
    for _, km in ipairs(existing) do
        pcall(api.nvim_buf_del_keymap, self.bufnr, "n", km.lhs)
    end

    local opts = { buffer = self.bufnr, silent = true, nowait = true }

    vim.keymap.set("n", "<CR>", function() self:press() end, opts)

    local current_buttons = self.pages[self.page] or {}
    for _, btn in ipairs(current_buttons) do
        vim.keymap.set("n", btn.sc, function()
            local ok, err = pcall(btn.fn)
            if not ok then log.error(err) end
        end, opts)
    end

    if self.page ~= "main" then
        vim.keymap.set("n", "<BS>", function()
            self:set_page("main")
        end, opts)
    end

    local function nav(delta)
        local rows = self:get_button_rows()
        if #rows == 0 then return end
        self.cursor_idx = math.max(1, math.min(self.cursor_idx + delta, #rows))
        self:_jump_to_row(rows[self.cursor_idx])
    end

    vim.keymap.set("n", "<Down>", function() nav(1) end, opts)
    vim.keymap.set("n", "<Up>", function() nav(-1) end, opts)
    vim.keymap.set("n", "<Tab>", function() nav(1) end, opts)
    vim.keymap.set("n", "<S-Tab>", function() nav(-1) end, opts)
end

Menu._active = nil

--- Refresh stats from API (called after submit, etc.)
--- Immediately increments local count, then re-fetches from API for accuracy.
function Menu.refresh_stats()
    local m = Menu._active
    if not m then return end
    if m._user_data and m._user_data.codeChallenges then
        m._user_data.codeChallenges.totalCompleted =
            (m._user_data.codeChallenges.totalCompleted or 0) + 1
    end
    fetch_user_data(m, function()
        if m.bufnr and api.nvim_buf_is_valid(m.bufnr) then
            m._redraw_only = true
            m:draw()
        end
    end)
end

---@return cw.ui.Menu
function Menu:init()
    local m = setmetatable({
        buttons = {},
        cursor_idx = 1,
        page = "main",
        _ns = api.nvim_create_namespace("codewars_menu"),
        _redraw_only = false,
    }, self)
    m.pages = build_pages(m)
    Menu._active = m
    return m
end

return Menu
