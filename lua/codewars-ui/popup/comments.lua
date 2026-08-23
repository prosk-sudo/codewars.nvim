--- Renders a solution's comment thread as plain text plus highlight spans.
---
--- Comments arrive as the markdown-lite Codewars lets people type (bold,
--- italics, code spans, fenced blocks, links, the odd <br>). Showing that
--- raw meant a pane full of `**` and `_`; relying on a markdown filetype
--- meant it only looked right for users with a treesitter grammar and a
--- conceal setup. This paints it directly, so every user sees the same
--- thing and nothing attaches to the scratch buffer.
local page = require("codewars.api.page")
local theme = require("codewars.theme")

local M = {}

---@alias cw.ui.Span { [1]: integer, [2]: integer, [3]: integer, [4]: string } row (0-based), col_start, col_end (byte), group

--- "8 kyu" -> -8, "2 dan" -> 2, anything else -> nil (rendered purple, like beta).
---@param rank_name string?
---@return integer?
function M.rank_id(rank_name)
    if type(rank_name) ~= "string" then return nil end
    local n, kind = rank_name:match("^(%d+)%s+(%a+)")
    if not n then return nil end
    return kind == "kyu" and -tonumber(n) or tonumber(n)
end

--- Render one line of inline markdown into text plus spans.
--- Handles `code`, **bold**, __bold__, *italic*, _italic_, [text](url).
---@param src string
---@param row integer
---@param col integer byte column the text starts at
---@return string text, cw.ui.Span[] spans
function M.inline(src, row, col)
    local out, spans = {}, {}
    local pos, cur = 1, col
    local function emit(text, group)
        if text == "" then return end
        out[#out + 1] = text
        if group then spans[#spans + 1] = { row, cur, cur + #text, group } end
        cur = cur + #text
    end

    local n = #src
    while pos <= n do
        local c = src:sub(pos, pos)
        local handled = false

        if c == "`" then
            local e = src:find("`", pos + 1, true)
            if e then
                emit(src:sub(pos + 1, e - 1), "codewars_comment_code")
                pos = e + 1
                handled = true
            end
        elseif c == "[" then
            -- The url is matched but not captured: only the text is shown.
            local text, e = src:match("^%[([^%]]+)%]%([^%)]+%)()", pos)
            if text then
                emit(text, "codewars_comment_link")
                pos = e
                handled = true
            end
        elseif c == "*" or c == "_" then
            local double = src:sub(pos, pos + 1)
            if double == "**" or double == "__" then
                local e = src:find(double, pos + 2, true)
                if e and e > pos + 2 then
                    local inner, sp = M.inline(src:sub(pos + 2, e - 1), row, cur)
                    emit(inner, "codewars_comment_bold")
                    vim.list_extend(spans, sp)
                    pos = e + 2
                    handled = true
                end
            else
                -- Single marker: opens at a word boundary with a non-space
                -- right after it, closes after a non-space and before a
                -- boundary — so snake_case, 2*3 and "a * b * c" are left alone.
                local before = pos == 1 and " " or src:sub(pos - 1, pos - 1)
                local after = src:sub(pos + 1, pos + 1)
                if before:match("[%s%p]") and after ~= "" and not after:match("%s") then
                    local e = src:find(c, pos + 1, true)
                    while e and not ((e == n or src:sub(e + 1, e + 1):match("[%s%p]"))
                        and not src:sub(e - 1, e - 1):match("%s")) do
                        e = src:find(c, e + 1, true)
                    end
                    if e and e > pos + 1 then
                        local inner, sp = M.inline(src:sub(pos + 1, e - 1), row, cur)
                        emit(inner, "codewars_comment_italic")
                        vim.list_extend(spans, sp)
                        pos = e + 1
                        handled = true
                    end
                end
            end
        end

        if not handled then
            -- Plain run up to the next possible marker.
            local e = src:find("[`%[%*_]", pos + 1) or (n + 1)
            emit(src:sub(pos, e - 1))
            pos = e
        end
    end

    return table.concat(out), spans
end

--- Normalise a comment body: decode entities, turn <br> into newlines,
--- drop other HTML tags, and trim trailing blank lines.
---@param body string
---@return string[] lines
local function body_lines(body)
    local s = page.unescape(body or "")
    s = s:gsub("<br%s*/?>", "\n"):gsub("</?[%w]+[^>]*>", "")
    s = s:gsub("\r", "")
    local lines = vim.split(s, "\n", { plain = true })
    while #lines > 0 and lines[#lines]:match("^%s*$") do
        lines[#lines] = nil
    end
    return lines
end

--- Render the flattened thread.
---@param comments cw.SolutionComment[]
---@return string[] lines, cw.ui.Span[] spans
function M.render(comments)
    local lines, spans = {}, {}
    local function push(text, row_spans)
        lines[#lines + 1] = text
        if row_spans then vim.list_extend(spans, row_spans) end
    end

    if #comments == 0 then
        push("No comments yet.", { { 0, 0, #"No comments yet.", "codewars_ref" } })
        return lines, spans
    end

    for i, c in ipairs(comments) do
        local depth = c.depth or 0
        local indent = string.rep("  ", depth)
        local row = #lines

        -- Header: marker, author, rank, date, score, spoiler.
        local parts, hs = {}, {}
        local col = 0
        local function add(text, group)
            parts[#parts + 1] = text
            if group then hs[#hs + 1] = { row, col, col + #text, group } end
            col = col + #text
        end
        add(indent)
        add(depth > 0 and "↳ " or "● ", "codewars_comment_guide")
        add(c.author or "?", "codewars_comment_author")
        if c.rank and c.rank ~= "" then
            add("  ")
            add(c.rank, theme.rank_hl(M.rank_id(c.rank)))
        end
        if c.created then
            add("  ·  ", "codewars_ref")
            add(c.created, "codewars_ref")
        end
        if (c.score or 0) ~= 0 then
            add("  ·  ", "codewars_ref")
            add(("▲ %d"):format(c.score), c.score > 0 and "codewars_ok" or "codewars_error")
        end
        if c.masked then
            add("   ")
            add("spoiler", "codewars_warning")
        end
        push(table.concat(parts), hs)

        -- Body: fenced code kept verbatim (one highlight), everything else
        -- through the inline renderer.
        local in_fence = false
        local body_indent = indent .. "  "
        for _, raw in ipairs(body_lines(c.body)) do
            local r = #lines
            if raw:match("^%s*```") then
                in_fence = not in_fence
            elseif in_fence or raw:match("^    ") then
                -- Inside a fence every character is code, indentation
                -- included; only the markdown "4-space indent" form has its
                -- marker stripped.
                local code = in_fence and raw or raw:gsub("^    ", "")
                local text = body_indent .. code
                push(text, { { r, #body_indent, #text, "codewars_comment_code" } })
            else
                local text, sp = M.inline(raw, r, #body_indent)
                push(body_indent .. text, sp)
            end
        end

        -- Breathing room between comments.
        if comments[i + 1] then
            push("")
        end
    end

    return lines, spans
end

--- Paint a rendered thread into a buffer.
---@param bufnr integer
---@param lines string[]
---@param spans cw.ui.Span[]
function M.paint(bufnr, lines, spans)
    require("codewars-ui.utils").buf_set_lines(bufnr, lines)
    local ns = vim.api.nvim_create_namespace("codewars_solution_comments")
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, s in ipairs(spans) do
        pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, s[4], s[1], s[2], s[3])
    end
end

return M
