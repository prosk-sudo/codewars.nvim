local config = require("codewars.config")
local lvls = vim.log.levels

---@class cw.Spinner
---@field index integer
---@field notif any
---@field timer uv.uv_timer_t
---@field msg string
---@field lvl integer
---@field opts table
---@field _closed boolean
local Spinner = {}
Spinner.__index = Spinner

local frames = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
local fps = 8

---@private
function Spinner:replace()
    if self.notif then
        local replace_id = type(self.notif) == "table" and self.notif.id or self.notif
        if replace_id then
            self.opts.replace = replace_id
            self.opts.id = replace_id
        end
    end

    local msg = self.msg
    if self.timer and self.timer:is_active() then
        msg = msg .. "..."
    end

    vim.schedule(function()
        self.notif = vim.notify(msg, self.lvl, self.opts)
    end)
end

---@private
function Spinner:loop()
    local interval = math.floor(1000 / fps)

    local function tick()
        self.index = (self.index + 1) % #frames
        self.opts.icon = frames[self.index + 1]
        self:replace()
    end

    self.timer:start(0, interval, vim.schedule_wrap(tick))
end

---@param msg string
function Spinner:update(msg)
    self.msg = msg
    self:replace()
end

---@param msg? string
function Spinner:success(msg)
    if msg then self.msg = msg end
    self.opts.icon = ""
    self:stop()
end

---@param msg? string
function Spinner:error(msg)
    if msg then self.msg = msg end
    self.lvl = lvls.ERROR
    self.opts.icon = "󰅘"
    self:stop()
end

---@private
function Spinner:stop()
    self.opts.timeout = 2500

    if self.timer and self.timer:is_active() then
        self.timer:stop()
    end

    if not self._closed and self.timer then
        self._closed = true
        self.timer:close(function()
            self:replace()
        end)
    end
end

---@param msg string
---@return cw.Spinner
function Spinner:start(msg)
    local s = setmetatable({
        index = 0,
        timer = vim.loop.new_timer(),
        msg = msg,
        lvl = lvls.INFO,
        _closed = false,
        opts = {
            hide_from_history = true,
            history = false,
            title = config.name,
            timeout = false,
        },
    }, self)

    s:loop()
    return s
end

return Spinner
