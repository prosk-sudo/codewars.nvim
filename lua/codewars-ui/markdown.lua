---@class cw.ui.Markdown
local M = {}

--- Codewars descriptions are markdown with raw HTML mixed in — authors reach
--- for `<blockquote>` for hints, `<br>` for spacing, `<b>`/`<i>` for emphasis,
--- `<center><img>` for diagrams. Neovim renders the buffer as markdown, so
--- those tags show up literally. This translates the ones that actually occur
--- into their markdown equivalents.
---
--- ALLOWLIST, never a generic tag stripper. Descriptions are full of generic
--- type parameters that look exactly like tags — `List<string>`, `vector<T>`,
--- `Dictionary<int, string>` — and a blanket `<[^>]+>` strip silently eats
--- them, corrupting every C#/C++/Java kata. Anything not named here is left
--- exactly as written.

-- Inline wrappers: tag -> the markdown delimiter placed on both sides.
local INLINE = {
    b = "**",
    strong = "**",
    i = "*",
    em = "*",
    code = "`",
}

-- Tags that carry no markdown meaning: drop the tag, keep the content.
local UNWRAP = { "center", "div", "span", "p" }

--- Lua patterns have no word boundary, so the obvious `<b[^>]*>` also matches
--- `<bool>` — and once it pairs with a real `</b>` further down the text it
--- deletes everything in between. Descriptions are full of generics that start
--- with an allowlisted tag name (`List<bool>`, `Dictionary<int, string>`), so
--- the tag name must be followed by `>` or whitespace to be an opener.
--- Scanned forward, not `<tag%s[^>]*>`: that is quadratic on malformed markup
--- (`("<b "):rep(20000)` took seconds).
---@param text string
---@param tag string
---@return { kind: string, s: integer, e: integer }[]
local function find_openers(text, tag)
    local openers = {}
    local head = "<" .. tag
    local pos = 1
    while true do
        local s = text:find(head, pos, true)
        if not s then return openers end
        local after = s + #head
        local e
        if text:sub(after, after) == ">" then
            e = after
        elseif text:find("^%s", after) then
            e = text:find(">", after, true)
            if not e then return openers end
        end
        if e then
            openers[#openers + 1] = { kind = "open", s = s, e = e }
            pos = e + 1
        else
            pos = after
        end
    end
end

--- Every opening and closing tag of `tag` in `text`, in document order. A tag
--- starting inside the previous one (a closer in an attribute value) is dropped.
---@param text string
---@param tag string
---@return { kind: string, s: integer, e: integer }[]
local function tag_tokens(text, tag)
    local found = find_openers(text, tag)
    local closing, pos = "</" .. tag .. "%s*>", 1
    while true do
        local s, e = text:find(closing, pos)
        if not s then break end
        found[#found + 1] = { kind = "close", s = s, e = e }
        pos = e + 1
    end
    table.sort(found, function(a, b) return a.s < b.s end)

    local tokens, last_end = {}, 0
    for _, token in ipairs(found) do
        if token.s > last_end then
            tokens[#tokens + 1] = token
            last_end = token.e
        end
    end
    return tokens
end

--- A function `repl(inner, opener)` may return nil to leave the construct as
--- written; a string has `%1` (inner text) and `%%` expanded as gsub does.
---@param repl string|fun(inner: string, opener: string): string?
---@param inner string
---@param opener string
---@return string?
local function expand(repl, inner, opener)
    if type(repl) == "function" then return repl(inner, opener) end
    return (repl:gsub("%%([%%1])", function(c) return c == "1" and inner or "%" end))
end

--- How deep one tag may nest and still convert; deeper ones stay as written.
--- Each closer copies its inner text, so unbounded nesting is quadratic.
local MAX_NEST_DEPTH = 64

--- Replace each paired `<tag>…</tag>`; a closer pairs with the nearest unclosed
--- opener (inner first). Unpaired and too-deep tags stay as written, no error.
---@param text string
---@param tag string
---@param repl string|fun(inner: string, opener: string): string?
---@return string
local function paired(text, tag, repl)
    -- `waiting` holds each unclosed opener's index in `out`, or `false` past
    -- the depth cap so its closer still pairs with it, not an outer opener.
    local out, waiting = {}, {}
    local pos = 1
    for _, token in ipairs(tag_tokens(text, tag)) do
        out[#out + 1] = text:sub(pos, token.s - 1)
        pos = token.e + 1
        local literal = text:sub(token.s, token.e)
        if token.kind == "open" then
            out[#out + 1] = literal
            waiting[#waiting + 1] = #waiting < MAX_NEST_DEPTH and #out
        elseif #waiting > 0 then
            local opener = table.remove(waiting)
            if opener then
                local opening, inner = out[opener], table.concat(out, "", opener + 1)
                for i = #out, opener, -1 do out[i] = nil end
                out[#out + 1] = expand(repl, inner, opening) or (opening .. inner .. literal)
            else
                out[#out + 1] = literal -- closes an opener past the depth cap
            end
        else
            out[#out + 1] = literal -- a closing tag with no opener
        end
    end
    out[#out + 1] = text:sub(pos)
    return table.concat(out)
end

--- Rewrite each single tag of `tag` on its own: `fn(tag_text, kind)` returns
--- the replacement, or nil to leave it as written. Same scan as `paired`.
---@param text string
---@param tag string
---@param fn fun(tag_text: string, kind: string): string?
---@return string
local function rewrite_tags(text, tag, fn)
    local out, pos = {}, 1
    for _, token in ipairs(tag_tokens(text, tag)) do
        local literal = text:sub(token.s, token.e)
        out[#out + 1] = text:sub(pos, token.s - 1)
        out[#out + 1] = fn(literal, token.kind) or literal
        pos = token.e + 1
    end
    out[#out + 1] = text:sub(pos)
    return table.concat(out)
end

--- The attribute text of an opening tag: `<a href="u">` gives `href="u"`.
---@param opener string
---@param tag string
---@return string
local function tag_attrs(opener, tag)
    return opener:sub(#tag + 3, -2) -- past "<tag" and the whitespace, before ">"
end

--- A placeholder stash. Anything handed to `keep` is swapped for an opaque
--- sentinel and restored verbatim at the very end, so no later conversion —
--- including the closing whitespace collapse — can rewrite or reflow it.
---@return string[] stash, fun(s: string): string keep
local function new_stash()
    local stash = {}
    return stash, function(s)
        stash[#stash + 1] = s
        return ("\1CWMD%d\1"):format(#stash)
    end
end

--- Stash fenced blocks and inline code so the conversions below never rewrite
--- a kata's sample code (some kata are *about* parsing HTML, and their
--- snippets contain real `<b>`/`<div>` text).
---@param text string
---@param keep fun(s: string): string
---@return string
local function protect(text, keep)
    text = text:gsub("```.-```", keep)
    text = text:gsub("`[^`\n]-`", keep)
    return text
end

--- Read one attribute out of a tag's attribute blob. Authors quote with
--- double, single, or no quotes; all three occur in real descriptions, so all
--- three are read. The leading `%s` keeps `href` from matching `data-href`.
---@param attrs string
---@param name string
---@return string?
local function attr(attrs, name)
    local blob = " " .. attrs
    return blob:match("%s" .. name .. '%s*=%s*"([^"]*)"')
        or blob:match("%s" .. name .. "%s*=%s*'([^']*)'")
        or blob:match("%s" .. name .. "%s*=%s*([^%s>]+)")
end

---@param text string
---@param stash string[]
---@return string
local function restore(text, stash)
    -- A stashed block can itself hold an earlier sentinel (a <pre> whose
    -- inline code was protected first), so expand until none is left; every
    -- entry predates its own sentinel, so this terminates.
    local n
    repeat
        text, n = text:gsub("\1CWMD(%d+)\1", function(i)
            return stash[tonumber(i)] or ""
        end)
    until n == 0
    return text
end

--- Render `<blockquote>` as a real markdown quote: every line gets `> `, so a
--- multi-line hint stays one quote block instead of only its first line.
---@param inner string
---@return string
local function blockquote(inner)
    local out = {}
    for line in (vim.trim(inner) .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = vim.trim(line) == "" and ">" or ("> " .. vim.trim(line))
    end
    return "\n\n" .. table.concat(out, "\n") .. "\n\n"
end

--- Convert the HTML Codewars actually embeds into markdown. Plain markdown
--- with no allowlisted tags comes back unchanged.
---@param text string?
---@return string
function M.from_html(text)
    -- The stash sentinels are built on \1, which no HTML page legitimately
    -- contains. Dropping any that arrive in the input means a page cannot
    -- forge a sentinel that restore() would expand into itself forever.
    if type(text) == "string" then
        text = text:gsub("\1", "")
    end
    if type(text) ~= "string" or text == "" then
        return text or ""
    end

    local stash, keep = new_stash()
    -- Math first: it claims ```math fences and `$…$` spans, and stashes
    -- every other fence/span on the way, so `$` inside code is never math.
    text = require("codewars-ui.math").render(text, keep)
    text = protect(text, keep)

    -- Line breaks and rules first: they change structure, not content.
    text = text:gsub("<br%s*/?>", "\n")
    text = text:gsub("<hr%s*/?>", "\n\n---\n\n")

    -- Blocks before inline, so a <b> inside a <blockquote> still converts.
    text = paired(text, "blockquote", blockquote)

    -- A <pre> block is code: stash the fence so the whitespace collapse at the
    -- end cannot eat the blank lines inside it, the way it would for any other
    -- generated block. Only the framing newlines are trimmed.
    text = paired(text, "pre", function(inner)
        -- `%s+$` retries from every space of a long run; `.*%S` does not.
        inner = (inner:gsub("^%s*\n", "")):match("^(.*%S)") or ""
        return "\n" .. keep("```\n" .. inner .. "\n```") .. "\n"
    end)

    -- Links and images keep their target. Attribute order varies and a bare
    -- <img> has no closing tag, so read the attribute blob rather than pinning
    -- a fixed order. Returning nil leaves a tag we cannot parse untouched.
    text = paired(text, "a", function(label, opener)
        local href = attr(tag_attrs(opener, "a"), "href")
        return href and ("[%s](%s)"):format(label, href) or nil
    end)
    text = rewrite_tags(text, "img", function(tag_text, kind)
        if kind ~= "open" then return nil end
        local attrs = tag_attrs(tag_text, "img")
        local src = attr(attrs, "src")
        return src and ("![%s](%s)"):format(attr(attrs, "alt") or "", src) or nil
    end)

    -- Lists: <li> becomes a bullet, the container just goes away.
    text = paired(text, "li", "\n- %1")
    for _, tag in ipairs({ "ul", "ol" }) do
        text = rewrite_tags(text, tag, function() return "\n" end)
    end

    for level = 1, 6 do
        text = paired(text, "h" .. level, function(inner)
            return "\n\n" .. ("#"):rep(level) .. " " .. vim.trim(inner) .. "\n\n"
        end)
    end

    -- Longest tag names first: `strong`/`em` must convert before `b`/`i` get a
    -- chance at them, and pairs() order is not deterministic in Lua.
    for _, tag in ipairs({ "strong", "code", "em", "b", "i" }) do
        text = paired(text, tag, INLINE[tag] .. "%1" .. INLINE[tag])
    end

    -- Superscript has no markdown form; `^2` is how kata authors write it in
    -- plain text anyway. Subscript borrows the same shape.
    text = paired(text, "sup", "^%1")
    text = paired(text, "sub", "_%1")

    for _, tag in ipairs(UNWRAP) do
        text = rewrite_tags(text, tag, function() return "" end)
    end

    -- The conversions above insert generous blank lines; collapse the runs so
    -- the panel does not end up mostly whitespace.
    text = text:gsub("\n%s*\n%s*\n+", "\n\n")

    return restore(text, stash)
end

return M
