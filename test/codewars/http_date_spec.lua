-- Retry-After is seconds or an HTTP-date (RFC 9110 section 10.2.3), read in pure Lua.
describe("api.httpdate", function()
    local httpdate = require("codewars.api.httpdate")

    -- RFC 9110 section 5.6.7 gives one instant in all three forms.
    local EXAMPLE = 784111777 -- 1994-11-06 08:49:37 UTC
    local NOW = 1792567680 -- Wed, 21 Oct 2026 07:28:00 GMT

    local function parse(str, now)
        return httpdate.parse(str, now or NOW)
    end

    describe("accepted forms", function()
        it("reads the IMF-fixdate form", function()
            assert.are.equal(EXAMPLE, parse("Sun, 06 Nov 1994 08:49:37 GMT"))
        end)

        it("reads the obsolete RFC 850 form", function()
            assert.are.equal(EXAMPLE, parse("Sunday, 06-Nov-94 08:49:37 GMT"))
        end)

        it("reads the obsolete asctime form, with its space-padded day", function()
            assert.are.equal(EXAMPLE, parse("Sun Nov  6 08:49:37 1994"))
            assert.are.equal(EXAMPLE + 4 * 86400, parse("Thu Nov 10 08:49:37 1994"))
        end)

        it("does not care about the case of names", function()
            assert.are.equal(EXAMPLE, parse("SUN, 06 NOV 1994 08:49:37 GMT"))
            assert.are.equal(EXAMPLE, parse("sun, 06 nov 1994 08:49:37 gmt"))
        end)

        it("ignores whitespace around the value", function()
            assert.are.equal(EXAMPLE, parse("  Sun, 06 Nov 1994 08:49:37 GMT \r\n"))
        end)

        it("reads the date the issue was filed with", function()
            assert.are.equal(NOW, parse("Wed, 21 Oct 2026 07:28:00 GMT"))
        end)
    end)

    describe("the epoch is exact", function()
        it("handles the epoch itself and the second before it", function()
            assert.are.equal(0, parse("Thu, 01 Jan 1970 00:00:00 GMT"))
            assert.are.equal(-1, parse("Wed, 31 Dec 1969 23:59:59 GMT"))
        end)

        it("counts a leap day, and the century rule for years divisible by 100", function()
            assert.are.equal(951782400, parse("Tue, 29 Feb 2000 00:00:00 GMT"))
            -- 1900 and 2100 are not leap years, 2000 is.
            assert.are.equal(-2203891200, parse("Thu, 01 Mar 1900 00:00:00 GMT"))
            assert.are.equal(4107542400, parse("Mon, 01 Mar 2100 00:00:00 GMT"))
        end)

        it("passes the 32-bit boundary", function()
            assert.are.equal(2147483648, parse("Tue, 19 Jan 2038 03:14:08 GMT"))
        end)

        it("does not depend on the machine's time zone", function()
            local saved = vim.env.TZ
            local ok, err = pcall(function()
                for _, zone in ipairs({ "Pacific/Auckland", "America/Los_Angeles", "UTC" }) do
                    vim.env.TZ = zone
                    assert.are.equal(EXAMPLE, parse("Sun, 06 Nov 1994 08:49:37 GMT"), zone)
                    assert.are.equal(EXAMPLE, parse("Sun Nov  6 08:49:37 1994"), zone)
                end
            end)
            vim.env.TZ = saved
            assert.is_true(ok, tostring(err))
        end)
    end)

    -- RFC 9110 section 5.6.7: a two-digit year more than 50 years ahead is the previous century.
    -- The whole timestamp is held against that line, which slides with the clock.
    describe("RFC 850 two-digit years", function()
        local NOW_2026 = 1795305600 -- 2026-11-22 00:00:00 UTC
        local NOON_2026 = 1795348800 -- 2026-11-22 12:00:00 UTC

        local function resolved(stamp, now)
            return parse("Sunday, " .. stamp .. " GMT", now)
        end

        local function year_of(yy, now)
            local at = parse(("Sunday, 06-Nov-%02d 08:49:37 GMT"):format(yy), now)
            return at and os.date("!*t", at).year
        end

        it("puts digits that read as the far future back a century", function()
            assert.are.equal(1994, year_of(94))
            assert.are.equal(1977, year_of(77)) -- 2077 is more than 50 years ahead
        end)

        it("keeps the ones within 50 years ahead, and the recent past", function()
            assert.are.equal(2026, year_of(26))
            assert.are.equal(2070, year_of(70))
            assert.are.equal(2000, year_of(0))
        end)

        -- The line is 2076-11-22; the year alone cannot tell its two sides apart.
        it("decides the 50th year by the full date, not by the year", function()
            -- 9 days past the line: more than 50 years ahead, so 1976.
            assert.are.equal(218246400, resolved("01-Dec-76 00:00:00", NOW_2026))
            -- 1 day short of the line: 2076.
            assert.are.equal(3373142400, resolved("21-Nov-76 00:00:00", NOW_2026))
        end)

        -- "More than 50 years" is strict: exactly 50 years ahead stays in the future.
        it("keeps a timestamp exactly 50 years ahead, and moves one second past it back", function()
            assert.are.equal(3373228800, resolved("22-Nov-76 00:00:00", NOW_2026)) -- 2076-11-22 00:00:00
            assert.are.equal(217468801, resolved("22-Nov-76 00:00:01", NOW_2026)) -- 1976-11-22 00:00:01
        end)

        it("decides the same day by the time of day", function()
            assert.are.equal(3373250400, resolved("22-Nov-76 06:00:00", NOON_2026)) -- 2076, before 12:00
            assert.are.equal(217533600, resolved("22-Nov-76 18:00:00", NOON_2026)) -- 1976, after 12:00
        end)

        it("measures from a 29 February without needing one 50 years on", function()
            local leap_day = 1835438400 -- 2028-02-29 12:00:00 UTC; 2078 has no 29 February
            assert.are.equal(3413318399, resolved("28-Feb-78 23:59:59", leap_day)) -- 2078
            assert.are.equal(257558400, resolved("01-Mar-78 00:00:00", leap_day)) -- 1978
        end)

        it("lets a date just past a century boundary resolve forward", function()
            local dec_2099 = 4100976000 -- 2099-12-15 00:00:00 UTC
            assert.are.equal(4102444800, resolved("01-Jan-00 00:00:00", dec_2099)) -- 2100-01-01
            assert.are_not.equal(946684800, resolved("01-Jan-00 00:00:00", dec_2099))

            local year_2090 = 3786912000 -- 2090-01-01 00:00:00 UTC
            assert.are.equal(4286940577, resolved("06-Nov-05 08:49:37", year_2090)) -- 2105
            assert.are.equal(3845177377, resolved("06-Nov-91 08:49:37", year_2090)) -- 2091
        end)

        it("still sends one more than 50 years ahead back, across the boundary", function()
            local dec_2099 = 4100976000 -- 2099-12-15 00:00:00 UTC
            -- 2150-01-01 is past 2149-12-15, so it is 2050.
            assert.are.equal(2524608000, resolved("01-Jan-50 00:00:00", dec_2099))
            -- Exactly 50 years ahead stays ahead, as it does in 2026; one second on does not.
            assert.are.equal(5678812800, resolved("15-Dec-49 00:00:00", dec_2099)) -- 2149-12-15
            assert.are.equal(2523139201, resolved("15-Dec-49 00:00:01", dec_2099)) -- 2049-12-15 00:00:01
        end)

        it("keeps a past date in the past", function()
            assert.are.equal(1131266977, resolved("06-Nov-05 08:49:37", NOW_2026)) -- 2005, not 2105
            assert.are.equal(689417377, resolved("06-Nov-91 08:49:37", NOW_2026)) -- 1991, not 2091
            assert.are.equal(1667724577, resolved("06-Nov-22 08:49:37", NOW_2026)) -- 2022

            local dec_2099 = 4100976000 -- 2099-12-15 00:00:00 UTC
            assert.are.equal(4076006400, resolved("01-Mar-99 00:00:00", dec_2099)) -- 2099, not 2199
            assert.are.equal(4101408000, resolved("20-Dec-99 00:00:00", dec_2099)) -- 2099, five days on
        end)
    end)

    describe("rejects", function()
        local function rejected(str)
            assert.is_nil(parse(str), str)
        end

        it("anything that is not a date", function()
            rejected("")
            rejected("soon")
            rejected("120")
            rejected("Wed")
            rejected("Wed, 21 Oct 2026")
        end)

        it("a time zone other than GMT", function()
            rejected("Wed, 21 Oct 2026 07:28:00 PST")
            rejected("Wed, 21 Oct 2026 07:28:00 +0100")
            rejected("Wed, 21 Oct 2026 07:28:00")
        end)

        it("a day, month or time that does not exist", function()
            rejected("Wed, 32 Oct 2026 07:28:00 GMT")
            rejected("Wed, 00 Oct 2026 07:28:00 GMT")
            rejected("Wed, 21 Foo 2026 07:28:00 GMT")
            rejected("Wed, 21 Oct 2026 24:00:00 GMT")
            rejected("Wed, 21 Oct 2026 07:60:00 GMT")
            rejected("Wed, 21 Oct 2026 07:28:61 GMT")
        end)

        it("a 29th of February in a year that has none", function()
            rejected("Thu, 29 Feb 2001 00:00:00 GMT")
            rejected("Mon, 29 Feb 1900 00:00:00 GMT")
        end)

        it("a weekday that is not one", function()
            rejected("Foo, 21 Oct 2026 07:28:00 GMT")
            rejected("Foo Oct 21 07:28:00 2026")
        end)

        it("text trailing or leading the date", function()
            rejected("Wed, 21 Oct 2026 07:28:00 GMT and then some")
            rejected("at Wed, 21 Oct 2026 07:28:00 GMT")
        end)

        it("a non-string without raising", function()
            assert.is_nil(httpdate.parse(nil, NOW))
            assert.is_nil(httpdate.parse(42, NOW))
        end)
    end)
end)
