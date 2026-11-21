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
--- every tag name is anchored on `>` or whitespace instead.
---@param tag string
---@return string[] # the bare form and the with-attributes form
local function openers(tag)
    return { "<" .. tag .. ">", "<" .. tag .. "%s[^>]*>" }
end

--- Every opening and closing tag of `tag` in `text`, in document order, as
--- `{ kind = "open"|"close", s = start, e = end }`. A tag that starts inside
--- the previous one (a bare `<b>` inside `<b <b>`) is not a tag of its own and
--- is dropped.
---@param text string
---@param tag string
---@return { kind: string, s: integer, e: integer }[]
local function tag_tokens(text, tag)
    local found = {}
    local function collect(pattern, kind, plain)
        local pos = 1
        while true do
            local s, e = text:find(pattern, pos, plain)
            if not s then return end
            found[#found + 1] = { kind = kind, s = s, e = e }
            pos = e + 1
        end
    end
    for _, pattern in ipairs(openers(tag)) do collect(pattern, "open") end
    collect("</" .. tag .. ">", "close", true)
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

--- The replacement for one matched construct: `repl(inner)` for a function,
--- or the string with its `%1` (the inner text) and `%%` expanded the way
--- gsub reads them. A function must return a string.
---@param repl string|fun(inner: string): string
---@param inner string
---@return string
local function expand(repl, inner)
    if type(repl) == "function" then return repl(inner) end
    return (repl:gsub("%%([%%1])", function(c) return c == "1" and inner or "%" end))
end

--- Replace each paired `<tag>…</tag>` construct, both with and without
--- attributes. Each closing tag pairs with the nearest unclosed opener of the
--- same tag, so `<blockquote>a<blockquote>b</blockquote>c</blockquote>` is two
--- constructs, not one cut at the first `</blockquote>`. The inner one is
--- converted first, and its result is part of the outer one's `inner`.
---
--- Unbalanced markup never errors: a closing tag with no opener, and an opener
--- with no closer, stay in the text exactly as written. One pass over the
--- tags, no recursion, so neither a long run of unmatched tags nor deep
--- nesting costs more than its length.
---@param text string
---@param tag string
---@param repl string|fun(inner: string): string
---@return string
local function paired(text, tag, repl)
    -- `out` is the converted text so far, in pieces. An opener goes in as
    -- literal text and its index in `out` onto `waiting`; if a closer claims
    -- it, everything after it is the construct's inner text and is replaced,
    -- and if none does, the opener is simply still there.
    local out, waiting = {}, {}
    local pos = 1
    for _, token in ipairs(tag_tokens(text, tag)) do
        out[#out + 1] = text:sub(pos, token.s - 1)
        pos = token.e + 1
        local literal = text:sub(token.s, token.e)
        if token.kind == "open" then
            out[#out + 1] = literal
            waiting[#waiting + 1] = #out
        elseif #waiting > 0 then
            local opener = table.remove(waiting)
            local inner = table.concat(out, "", opener + 1)
            for i = #out, opener, -1 do out[i] = nil end
            out[#out + 1] = expand(repl, inner)
        else
            out[#out + 1] = literal -- a closing tag with no opener
        end
    end
    out[#out + 1] = text:sub(pos)
    return table.concat(out)
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
        inner = inner:gsub("^%s*\n", ""):gsub("%s+$", "")
        return "\n" .. keep("```\n" .. inner .. "\n```") .. "\n"
    end)

    -- Links and images keep their target. Attribute order varies and a bare
    -- <img> has no closing tag, so read the attribute blob rather than pinning
    -- a fixed order. Returning nil leaves a tag we cannot parse untouched.
    text = text:gsub("<a%s([^>]*)>(.-)</a>", function(attrs, label)
        local href = attr(attrs, "href")
        return href and ("[%s](%s)"):format(label, href) or nil
    end)
    text = text:gsub("<img%s([^>]*)>", function(attrs)
        local src = attr(attrs, "src")
        return src and ("![%s](%s)"):format(attr(attrs, "alt") or "", src) or nil
    end)

    -- Lists: <li> becomes a bullet, the container just goes away.
    text = paired(text, "li", "\n- %1")
    text = text:gsub("</?[ou]l>", "\n"):gsub("</?[ou]l%s[^>]*>", "\n")

    text = text:gsub("<h(%d)[^>]*>(.-)</h%d>", function(level, inner)
        return "\n\n" .. ("#"):rep(tonumber(level)) .. " " .. vim.trim(inner) .. "\n\n"
    end)

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
        text = text:gsub("</?" .. tag .. ">", ""):gsub("</?" .. tag .. "%s[^>]*>", "")
    end

    -- The conversions above insert generous blank lines; collapse the runs so
    -- the panel does not end up mostly whitespace.
    text = text:gsub("\n%s*\n%s*\n+", "\n\n")

    return restore(text, stash)
end

return M
