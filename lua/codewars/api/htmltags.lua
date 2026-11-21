--- A small HTML tag tokenizer, for telling real tags from text that only looks
--- like them.
---
--- A page's markup is not what a pattern for `<div` finds: `<!-- <div> -->`,
--- a `<script>` holding an HTML template, a `title="a > b <div>"` attribute
--- are all text. One forward pass reads the page the way a browser would
--- split it and yields only the tags that are really there, so that what is
--- built on it -- finding an element's end by counting its open and close
--- tags, say -- counts nothing else.
---
--- What is not a tag:
---   * `<!-- ... -->`, skipped whole; one never closed runs to the end of the
---     page. `<!-->` and `<!--->` are whole comments, as in HTML.
---   * `<!DOCTYPE ...>`, `<![CDATA[ ... >`, `<? ... >` and `</ ... >` with no
---     name: skipped to the next `>`, as the bogus comments they are.
---   * `<script>` and `<style>` (raw text), `<textarea>` and `<title>`
---     (escapable raw text): what is between the tags is text. The element is
---     skipped whole, up to the first closing `</script`, `</style`,
---     `</textarea` or `</title` (any case); nothing inside is a tag. One
---     never closed runs to the end of the page.
---   * `<template>`: its contents are inert (a browser keeps them out of the
---     page). The element is skipped whole up to its matching `</template>`,
---     counting nested templates; comments and scripts inside are read as
---     such, so a `</template>` in a script does not end it. One never closed
---     runs to the end of the page.
---
--- Inside a tag, a quoted attribute value (`"..."` or `'...'`, which can only
--- start right after an `=`) is skipped, so a `>` or a `<div` in it neither
--- ends the tag nor counts as one. The same walk reads the attributes: each
--- tag's `attrs` maps the lower-cased names to their values (quoted or not,
--- `""` for a bare name), the first of a repeated name winning, as in a
--- browser. Text in one attribute's value is never read as another attribute.
--- The page is read once, front to back, with no backtracking: every `find`
--- starts where the last one stopped.
---@class cw.Api.HtmlTags
local htmltags = {}

---@class cw.HtmlTag
---@field name string lower-case
---@field close boolean a closing tag (`</name>`)
---@field start integer position of its `<`
---@field finish integer position of its `>`
---@field attrs table<string, string> lower-cased attribute name to value
---@field empty boolean an opening tag with no contents and no closing tag: a void element, or one written `<name/>`

local VOID = {
    area = true, base = true, br = true, col = true, embed = true, hr = true, img = true,
    input = true, link = true, meta = true, param = true, source = true, track = true, wbr = true,
}

--- A pattern for `name` in any case: `[sS][cC]...`.
local function any_case(name)
    return (name:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

--- Raw-text elements, and where each one's text ends: its closing tag.
local RAW_TEXT_END = {
    script = "</" .. any_case("script") .. "[%s/>]",
    style = "</" .. any_case("style") .. "[%s/>]",
    textarea = "</" .. any_case("textarea") .. "[%s/>]",
    title = "</" .. any_case("title") .. "[%s/>]",
}

--- Read the attributes of the tag whose name ends just before `i`, up to its
--- `>`. A quote opens a value only straight after an `=`.
---@param html string
---@param i integer
---@return integer? gt position of the closing `>`; nil when the page ends first
---@return table<string, string>? attrs
local function scan_attributes(html, i)
    local attrs = {}
    while true do
        local _, space_end = html:find("^[%s/]*", i)
        i = space_end + 1
        local byte = html:byte(i)
        if not byte then return nil end
        if byte == 62 then return i, attrs end -- ">"

        local _, name_end = html:find("^[^%s/>][^%s=/>]*", i)
        local name = html:sub(i, name_end):lower()
        _, space_end = html:find("^%s*", name_end + 1)
        i = space_end + 1

        local value = "" -- a bare name has no value
        if html:byte(i) == 61 then -- "="
            _, space_end = html:find("^%s*", i + 1)
            i = space_end + 1
            local quote = html:byte(i)
            if quote == 34 or quote == 39 then
                local close = html:find(quote == 34 and '"' or "'", i + 1, true)
                if not close then return nil end
                value, i = html:sub(i + 1, close - 1), close + 1
            else
                local _, value_end = html:find("^[^%s>]*", i)
                value, i = html:sub(i, value_end), value_end + 1
            end
        end
        if attrs[name] == nil then attrs[name] = value end
    end
end

--- Read the tag that starts at `lt`, which is `<` and a letter, or `</` and
--- a letter.
---@param html string
---@param lt integer
---@return cw.HtmlTag? tag nil when the page ends inside it
local function read_tag(html, lt)
    local closing = html:byte(lt + 1) == 47
    local name = html:match(closing and "^</(%a[^%s/>]*)" or "^<(%a[^%s/>]*)", lt)
    local gt, attrs = scan_attributes(html, lt + #name + (closing and 2 or 1))
    if not gt then return nil end
    name = name:lower()
    local self_closed = html:byte(gt - 1) == 47 and gt - 1 > lt + #name
    return {
        name = name, close = closing, start = lt, finish = gt,
        attrs = attrs,
        empty = not closing and (VOID[name] or self_closed) or false,
    }
end

--- Where a `<` that is not a tag ends, or nil when it starts a tag (or is
--- plain text).
---@param html string
---@param lt integer
---@return integer? last position of the comment-like run
local function comment_end(html, lt)
    local byte = html:byte(lt + 1)
    local close
    if byte == 33 then -- "<!"
        if html:find("^<!%-%-", lt) then
            -- From the first dash, so that `<!-->` and `<!--->` end at once.
            close = html:find("-->", lt + 2, true)
            return close and close + 2 or #html
        end
    elseif byte ~= 63 and not (byte == 47 and not html:find("^%a", lt + 2)) then -- "<?", "</" with no name
        return nil
    end
    close = html:find(">", lt + 2, true)
    return close or #html
end

--- Blank out `ranges` (pairs of first and last position) in `html`, keeping
--- every position where it was.
local function mask(html, ranges)
    if #ranges == 0 then return html end
    local parts, copied = {}, 0
    for i = 1, #ranges, 2 do
        local from, to = ranges[i], ranges[i + 1]
        parts[#parts + 1] = html:sub(copied + 1, from - 1)
        parts[#parts + 1] = (" "):rep(to - from + 1)
        copied = to
    end
    parts[#parts + 1] = html:sub(copied + 1)
    return table.concat(parts)
end

--- Read a page's tags.
---
--- Returns them in order, and the page with everything that is not markup
--- (the comments, scripts, styles and templates above) blanked out with spaces:
--- the same length, so a tag's positions are positions in it too. Text read
--- from between tags there is the text a browser would show.
---@param html string
---@return cw.HtmlTag[] tags
---@return string text
function htmltags.scan(html)
    local tags, blanks = {}, {}
    local len = #html
    local pos = 1
    local templates, template_start = 0, nil

    --- Outside a template; inside one the template is blanked as a whole.
    local function blank(from, to)
        if templates == 0 then
            blanks[#blanks + 1], blanks[#blanks + 2] = from, to
        end
    end

    while true do
        local lt = html:find("<", pos, true)
        if not lt then break end

        local stop = comment_end(html, lt)
        if stop then
            blank(lt, stop)
            pos = stop + 1
        elseif html:find("^</?%a", lt) then
            local tag = read_tag(html, lt)
            if not tag then break end -- the page ends inside the tag
            pos = tag.finish + 1

            if not tag.close and RAW_TEXT_END[tag.name] then
                local text_end = html:find(RAW_TEXT_END[tag.name], pos)
                stop = (text_end and html:find(">", text_end, true)) or len
                blank(tag.start, stop)
                pos = stop + 1
            elseif tag.name == "template" then
                if not tag.close then
                    if templates == 0 then template_start = tag.start end
                    templates = templates + 1
                elseif templates > 0 then
                    templates = templates - 1
                    if templates == 0 then blank(template_start, tag.finish) end
                end
            elseif templates == 0 then
                tags[#tags + 1] = tag
            end
        else
            pos = lt + 1 -- a "<" in text
        end
    end

    if templates > 0 then
        templates = 0
        blank(template_start, len)
    end
    return tags, mask(html, blanks)
end

return htmltags
