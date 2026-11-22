--- HTTP-date parsing (RFC 9110 section 5.6.7), for `Retry-After`.
---
--- Pure Lua on purpose: `vim.fn.strptime` follows the locale and is missing on Windows, and
--- `os.time` on a table reads LOCAL time. The epoch is counted from the calendar date.
---@class cw.Api.HttpDate
local httpdate = {}

local MONTHS = {
    jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}
local SHORT_DAYS = { sun = true, mon = true, tue = true, wed = true, thu = true, fri = true, sat = true }
local LONG_DAYS = {
    sunday = true, monday = true, tuesday = true, wednesday = true,
    thursday = true, friday = true, saturday = true,
}
local MONTH_LENGTHS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local SECONDS_PER_DAY = 86400
--- RFC 9110: a two-digit year more than this many years after now is the previous century.
local MAX_YEARS_AHEAD = 50

---@param year integer
---@return boolean
local function is_leap(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

---@param year integer
---@param month integer 1-12
---@return integer
local function days_in_month(year, month)
    if month == 2 and is_leap(year) then return 29 end
    return MONTH_LENGTHS[month]
end

--- Days from 1970-01-01 to a proleptic Gregorian date (Hinnant's days-from-civil; the year starts in March).
---@param year integer
---@param month integer 1-12
---@param day integer 1-31
---@return integer
local function days_from_civil(year, month, day)
    if month <= 2 then year = year - 1 end
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local shifted_month = (month + 9) % 12 -- March = 0 ... February = 11
    local day_of_year = math.floor((153 * shifted_month + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100) + day_of_year
    return era * 146097 + day_of_era - 719468
end

--- Orders calendar moments like time does, with no epoch (the limit can be a 29 February that
--- does not exist). Each field must stay under its multiplier.
local function moment_key(year, month, day, hour, min, sec)
    return ((((year * 13 + month) * 32 + day) * 24 + hour) * 60 + min) * 61 + sec
end

--- The year a two-digit RFC 850 year means, per MAX_YEARS_AHEAD. The whole date and time is
--- held against the limit, not the year alone; exactly that far ahead still counts as ahead.
---@param yy integer 0-99
---@param now integer epoch seconds
---@return integer
local function expand_year(yy, month, day, hour, min, sec, now)
    local at = os.date("!*t", now)
    local limit = moment_key(at.year + MAX_YEARS_AHEAD, at.month, at.day, at.hour, at.min, at.sec)
    local this_century = at.year - at.year % 100 + yy
    for _, year in ipairs({ this_century + 100, this_century }) do
        if moment_key(year, month, day, hour, min, sec) <= limit then return year end
    end
    -- The previous century is behind this year, so it is never too far ahead.
    return this_century - 100
end

---@return integer? year, integer? month, integer? day, integer? hour, integer? min, integer? sec
local function read_imf_fixdate(text)
    local weekday, day, month, year, hour, min, sec =
        text:match("^(%a%a%a), (%d%d) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d) gmt$")
    if not (weekday and SHORT_DAYS[weekday]) then return nil end
    return tonumber(year), MONTHS[month], tonumber(day), tonumber(hour), tonumber(min), tonumber(sec)
end

---@return integer? year, integer? month, integer? day, integer? hour, integer? min, integer? sec
local function read_rfc850(text, now)
    local weekday, day, month, yy, hour, min, sec =
        text:match("^(%a+), (%d%d)%-(%a%a%a)%-(%d%d) (%d%d):(%d%d):(%d%d) gmt$")
    if not (weekday and LONG_DAYS[weekday] and MONTHS[month]) then return nil end
    month, day, hour, min, sec = MONTHS[month], tonumber(day), tonumber(hour), tonumber(min), tonumber(sec)
    return expand_year(tonumber(yy), month, day, hour, min, sec, now), month, day, hour, min, sec
end

--- asctime has no zone; HTTP reads it as GMT. Its day is space-padded.
---@return integer? year, integer? month, integer? day, integer? hour, integer? min, integer? sec
local function read_asctime(text)
    local weekday, month, day, hour, min, sec, year =
        text:match("^(%a%a%a) (%a%a%a) ([ %d]%d) (%d%d):(%d%d):(%d%d) (%d%d%d%d)$")
    if not (weekday and SHORT_DAYS[weekday]) then return nil end
    return tonumber(year), MONTHS[month], tonumber(day), tonumber(hour), tonumber(min), tonumber(sec)
end

--- Whether the fields name a real moment. A 60th second (leap second) is allowed.
local function is_valid(year, month, day, hour, min, sec)
    if not (year and month and day and hour and min and sec) then return false end
    return day >= 1 and day <= days_in_month(year, month)
        and hour <= 23 and min <= 59 and sec <= 60
end

--- Read an HTTP-date as a UTC epoch: IMF-fixdate (`Wed, 21 Oct 2026 07:28:00 GMT`) or the
--- obsolete RFC 850 and asctime forms. Names are case-insensitive; the weekday is not checked.
---@param text any
---@param now? integer epoch seconds, to place a two-digit year; default os.time()
---@return integer? epoch nil when `text` is not a valid HTTP-date
function httpdate.parse(text, now)
    if type(text) ~= "string" then return nil end
    text = text:match("^%s*(.-)%s*$"):lower()
    now = now or os.time()

    local year, month, day, hour, min, sec = read_imf_fixdate(text)
    if not year then year, month, day, hour, min, sec = read_rfc850(text, now) end
    if not year then year, month, day, hour, min, sec = read_asctime(text) end
    if not is_valid(year, month, day, hour, min, sec) then return nil end

    return days_from_civil(year, month, day) * SECONDS_PER_DAY + hour * 3600 + min * 60 + sec
end

return httpdate
