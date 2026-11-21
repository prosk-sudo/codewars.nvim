--- HTTP-date parsing (RFC 9110 section 5.6.7), for `Retry-After`.
---
--- Pure Lua on purpose. `vim.fn.strptime` follows the locale and the C
--- library's idea of a time zone, and does not exist on Windows; `os.time`
--- on a table reads its fields as LOCAL time, so it is wrong by the zone's
--- offset. The epoch here is counted from the calendar date instead.
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
--- RFC 9110: a two-digit year more than this many years ahead of now is
--- really the latest past year with those digits.
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

--- Days from 1970-01-01 to the given proleptic Gregorian date (negative
--- before it). Howard Hinnant's days-from-civil: years run March to
--- February so the leap day is the last day of its year, and every 400 years
--- (146097 days) repeat exactly.
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

--- The year a two-digit RFC 850 year means: the one ending in `yy` within
--- the window from 49 years back to MAX_YEARS_AHEAD years ahead of now.
---@param yy integer 0-99
---@param now integer epoch seconds
---@return integer
local function expand_year(yy, now)
    local this_year = os.date("!*t", now).year
    return yy + 100 * math.floor((this_year + MAX_YEARS_AHEAD - yy) / 100)
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
    if not (weekday and LONG_DAYS[weekday]) then return nil end
    return expand_year(tonumber(yy), now), MONTHS[month], tonumber(day), tonumber(hour), tonumber(min), tonumber(sec)
end

--- asctime has no zone; HTTP reads it as GMT. Its day is space-padded.
---@return integer? year, integer? month, integer? day, integer? hour, integer? min, integer? sec
local function read_asctime(text)
    local weekday, month, day, hour, min, sec, year =
        text:match("^(%a%a%a) (%a%a%a) ([ %d]%d) (%d%d):(%d%d):(%d%d) (%d%d%d%d)$")
    if not (weekday and SHORT_DAYS[weekday]) then return nil end
    return tonumber(year), MONTHS[month], tonumber(day), tonumber(hour), tonumber(min), tonumber(sec)
end

--- Whether the fields name a moment that exists. A 60th second is allowed
--- (a leap second); it simply lands on the next minute.
local function is_valid(year, month, day, hour, min, sec)
    if not (year and month and day and hour and min and sec) then return false end
    return day >= 1 and day <= days_in_month(year, month)
        and hour <= 23 and min <= 59 and sec <= 60
end

--- Read an HTTP-date as a UTC epoch. Takes the preferred IMF-fixdate form
--- (`Wed, 21 Oct 2026 07:28:00 GMT`) and the two obsolete forms a recipient
--- must still accept: RFC 850 (`Sunday, 06-Nov-94 08:49:37 GMT`) and
--- asctime (`Sun Nov  6 08:49:37 1994`). Names are case-insensitive. The
--- weekday must be a real one but is not checked against the date.
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
