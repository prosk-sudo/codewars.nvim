--- LaTeX math in kata descriptions, rendered as readable plain text.
---
--- Codewars typesets `$…$`, `$$…$$` and ```math blocks with KaTeX. A Neovim
--- buffer cannot typeset, so the next best thing is to turn the LaTeX into
--- the Unicode a person would type: `\frac{a+b}{2}` → `(a+b)/2`, `x^2` → `x²`,
--- `\alpha \le \sqrt{n}` → `α ≤ √n`, `\\` → a line break. Anything not
--- understood is kept as written (minus the backslash), never dropped.
---
--- Output is wrapped as code — a span for inline math, a fence for a block —
--- so the markdown renderer leaves `_`, `*` and `<` inside it alone.
---@class cw.ui.Math
local M = {}

local SYMBOLS = {
    alpha = "α", beta = "β", gamma = "γ", delta = "δ", epsilon = "ε", varepsilon = "ε", zeta = "ζ",
    eta = "η", theta = "θ", vartheta = "ϑ", iota = "ι", kappa = "κ", lambda = "λ", mu = "μ", nu = "ν",
    xi = "ξ", pi = "π", rho = "ρ", sigma = "σ", tau = "τ", upsilon = "υ", phi = "φ", varphi = "φ",
    chi = "χ", psi = "ψ", omega = "ω",
    Gamma = "Γ", Delta = "Δ", Theta = "Θ", Lambda = "Λ", Xi = "Ξ", Pi = "Π", Sigma = "Σ", Phi = "Φ",
    Psi = "Ψ", Omega = "Ω",
    le = "≤", leq = "≤", ge = "≥", geq = "≥", ne = "≠", neq = "≠", times = "×", cdot = "·", pm = "±",
    mp = "∓", div = "÷", infty = "∞", to = "→", rightarrow = "→", leftarrow = "←", Rightarrow = "⇒",
    Leftarrow = "⇐", leftrightarrow = "↔", Leftrightarrow = "⇔", iff = "⇔", implies = "⇒", mapsto = "↦",
    ["in"] = "∈", notin = "∉", ni = "∋", subset = "⊂", subseteq = "⊆", supset = "⊃", supseteq = "⊇",
    cup = "∪", cap = "∩", setminus = "∖", forall = "∀", exists = "∃", nexists = "∄", neg = "¬", lnot = "¬",
    land = "∧", lor = "∨", wedge = "∧", vee = "∨", oplus = "⊕", otimes = "⊗",
    sum = "∑", prod = "∏", int = "∫", iint = "∬", oint = "∮", partial = "∂", nabla = "∇",
    approx = "≈", equiv = "≡", sim = "∼", simeq = "≃", cong = "≅", propto = "∝", ll = "≪", gg = "≫",
    ldots = "…", cdots = "⋯", dots = "…", vdots = "⋮", ddots = "⋱",
    lfloor = "⌊", rfloor = "⌋", lceil = "⌈", rceil = "⌉", langle = "⟨", rangle = "⟩",
    emptyset = "∅", varnothing = "∅", degree = "°", circ = "∘", bullet = "•", star = "⋆", ast = "∗",
    mid = "|", vert = "|", Vert = "‖", perp = "⊥", parallel = "∥", angle = "∠", triangle = "△",
    prime = "′", hbar = "ℏ", ell = "ℓ", Re = "ℜ", Im = "ℑ", aleph = "ℵ", top = "⊤", bot = "⊥",
    quad = "  ", qquad = "    ", space = " ", enspace = " ", thinspace = " ",
    -- operators that read as their name
    sin = "sin", cos = "cos", tan = "tan", cot = "cot", sec = "sec", csc = "csc", arcsin = "arcsin",
    arccos = "arccos", arctan = "arctan", sinh = "sinh", cosh = "cosh", tanh = "tanh", log = "log",
    ln = "ln", lg = "lg", exp = "exp", min = "min", max = "max", gcd = "gcd", lcm = "lcm", det = "det",
    dim = "dim", deg = "deg", lim = "lim", sup = "sup", inf = "inf", arg = "arg", bmod = "mod",
    ["and"] = "and", ["or"] = "or", ["not"] = "not", mod = "mod", pmod = "mod",
}

local BLACKBOARD = { N = "ℕ", Z = "ℤ", Q = "ℚ", R = "ℝ", C = "ℂ", P = "ℙ", H = "ℍ" }

-- Combining marks placed after the argument.
local ACCENTS = {
    hat = "\204\130", bar = "\204\132", overline = "\204\133", vec = "\226\131\151",
    tilde = "\204\131", dot = "\204\135", ddot = "\204\136",
}

local SUP = {
    ["0"] = "⁰", ["1"] = "¹", ["2"] = "²", ["3"] = "³", ["4"] = "⁴", ["5"] = "⁵", ["6"] = "⁶",
    ["7"] = "⁷", ["8"] = "⁸", ["9"] = "⁹", ["+"] = "⁺", ["-"] = "⁻", ["="] = "⁼", ["("] = "⁽",
    [")"] = "⁾", a = "ᵃ", b = "ᵇ", c = "ᶜ", d = "ᵈ", e = "ᵉ", f = "ᶠ", g = "ᵍ", h = "ʰ", i = "ⁱ",
    j = "ʲ", k = "ᵏ", l = "ˡ", m = "ᵐ", n = "ⁿ", o = "ᵒ", p = "ᵖ", r = "ʳ", s = "ˢ", t = "ᵗ",
    u = "ᵘ", v = "ᵛ", w = "ʷ", x = "ˣ", y = "ʸ", z = "ᶻ", T = "ᵀ", [" "] = "",
}
local SUB = {
    ["0"] = "₀", ["1"] = "₁", ["2"] = "₂", ["3"] = "₃", ["4"] = "₄", ["5"] = "₅", ["6"] = "₆",
    ["7"] = "₇", ["8"] = "₈", ["9"] = "₉", ["+"] = "₊", ["-"] = "₋", ["="] = "₌", ["("] = "₍",
    [")"] = "₎", a = "ₐ", e = "ₑ", h = "ₕ", i = "ᵢ", j = "ⱼ", k = "ₖ", l = "ₗ", m = "ₘ", n = "ₙ",
    o = "ₒ", p = "ₚ", r = "ᵣ", s = "ₛ", t = "ₜ", u = "ᵤ", v = "ᵥ", x = "ₓ", [" "] = "",
}

local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

--- Map every character of `s` through `map`, or nil when one has no glyph.
---@param s string
---@param map table<string, string>
---@return string?
local function script(s, map)
    local out = {}
    for ch in s:gmatch(UTF8_CHAR) do
        local m = map[ch]
        if not m then return nil end
        out[#out + 1] = m
    end
    return table.concat(out)
end

--- Parenthesise unless `s` is a single token (one number, name or glyph).
---@param s string
---@return string
local function group(s)
    if s == "" then return s end
    if s:match("^[%w%.]+$") or select(2, s:gsub(UTF8_CHAR, "")) == 1 then
        return s
    end
    return "(" .. s .. ")"
end

--- Read one argument starting at `i`: a `{…}` group (nesting-aware), a
--- `\command`, or a single character. Returns the argument's raw text and the
--- index just past it.
---@param s string
---@param i integer
---@return string, integer
local function read_arg(s, i)
    while s:sub(i, i) == " " do i = i + 1 end
    local c = s:sub(i, i)
    if c == "{" then
        local depth, j = 0, i
        while j <= #s do
            local d = s:sub(j, j)
            if d == "{" then depth = depth + 1 end
            if d == "}" then
                depth = depth - 1
                if depth == 0 then return s:sub(i + 1, j - 1), j + 1 end
            end
            j = j + 1
        end
        return s:sub(i + 1), #s + 1
    end
    if c == "\\" then
        local cmd = s:match("^\\%a+", i) or s:sub(i, i + 1)
        return cmd, i + #cmd
    end
    local ch = s:match("^" .. UTF8_CHAR, i) or ""
    return ch, i + #ch
end

local convert

--- One `\command`; `i` is just past the backslash and name.
---@return string out, integer next
local function command(name, s, i)
    if name == "frac" or name == "dfrac" or name == "tfrac" then
        local a, i2 = read_arg(s, i)
        local b, i3 = read_arg(s, i2)
        return group(convert(a)) .. "/" .. group(convert(b)), i3
    elseif name == "sqrt" then
        local n = ""
        if s:sub(i, i) == "[" then
            local close = s:find("]", i, true) or #s
            local idx = convert(s:sub(i + 1, close - 1))
            n = script(idx, SUP) or idx
            i = close + 1
        end
        local a, i2 = read_arg(s, i)
        return n .. "√" .. group(convert(a)), i2
    elseif name == "text" or name == "textrm" or name == "textbf" or name == "textit" or name == "operatorname" then
        local a, i2 = read_arg(s, i)
        return a, i2
    elseif name == "mathrm" or name == "mathbf" or name == "mathit" or name == "mathcal" or name == "boldsymbol" or name == "bm" then
        local a, i2 = read_arg(s, i)
        return convert(a), i2
    elseif name == "mathbb" then
        local a, i2 = read_arg(s, i)
        return BLACKBOARD[a] or convert(a), i2
    elseif ACCENTS[name] then
        local a, i2 = read_arg(s, i)
        return convert(a) .. ACCENTS[name], i2
    elseif name == "left" or name == "right" or name == "big" or name == "Big" or name == "bigl" or name == "bigr" then
        -- Sizing only; the delimiter that follows is kept, `.` (invisible) is dropped.
        if s:sub(i, i) == "." then return "", i + 1 end
        return "", i
    elseif name == "begin" or name == "end" then
        local _, i2 = read_arg(s, i)
        return "", i2
    elseif name == "displaystyle" or name == "textstyle" or name == "limits" or name == "nolimits" then
        return "", i
    elseif SYMBOLS[name] then
        return SYMBOLS[name], i
    end
    return name, i
end

--- LaTeX → text.
---@param s string
---@return string
function convert(s)
    local out = {}
    local i = 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" then
            local name = s:match("^\\(%a+)", i)
            if name then
                local text, i2 = command(name, s, i + 1 + #name)
                out[#out + 1] = text
                i = i2
            else
                local ch = s:sub(i + 1, i + 1)
                if ch == "\\" then
                    out[#out + 1] = "\n"
                elseif ch == "," or ch == ";" or ch == ":" or ch == " " then
                    out[#out + 1] = " "
                elseif ch == "!" then
                    out[#out + 1] = ""
                else
                    out[#out + 1] = ch
                end
                i = i + 2
            end
        elseif c == "^" or c == "_" then
            local a, i2 = read_arg(s, i + 1)
            local inner = convert(a)
            local mapped = script(inner, c == "^" and SUP or SUB)
            if mapped then
                out[#out + 1] = mapped
            else
                out[#out + 1] = c .. group(inner)
            end
            i = i2
        elseif c == "{" or c == "}" then
            i = i + 1
        elseif c == "&" or c == "~" then
            out[#out + 1] = " "
            i = i + 1
        else
            local ch = s:match("^" .. UTF8_CHAR, i)
            out[#out + 1] = ch
            i = i + #ch
        end
    end
    local text = table.concat(out)
    -- Tidy: collapse runs of spaces, trim each line and the ends.
    text = text:gsub("[ \t]+", " "):gsub(" *\n *", "\n"):gsub("\n+", "\n")
    text = text:gsub("%( ", "("):gsub(" %)", ")"):gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

M.to_text = convert

--- A block of math as a fenced code block: one line per `\\`.
---@param latex string
---@return string
local function block(latex)
    local text = convert(latex)
    if text == "" then return "" end
    return "\n```\n" .. text .. "\n```\n"
end

--- Inline math is worth converting when it looks like math rather than a
--- price: no leading/trailing space and something beyond bare digits.
---@param latex string
---@return boolean
local function looks_like_math(latex)
    if latex == "" or latex:match("^%s") or latex:match("%s$") then return false end
    return latex:match("[%a\\^_]") ~= nil
end

--- Replace every math region in `text` with its rendering, handing each
--- result (and every non-math code fence / span) to `keep` so later markdown
--- passes cannot touch them.
---@param text string
---@param keep fun(s: string): string
---@return string
function M.render(text, keep)
    -- Fences first: a ```math fence is math, any other fence is code and
    -- must hide its `$` from the passes below.
    text = text:gsub("```(%w*)[ \t]*\n(.-)```", function(lang, body)
        if lang == "math" or lang == "latex" or lang == "tex" then
            return keep(block(body))
        end
        return keep("```" .. lang .. "\n" .. body .. "```")
    end)
    -- Authors also write `$…$` inside a code span, and Codewars renders
    -- that as math too. A span that is entirely `$…$` is math; any other
    -- span (`$HOME`) is code.
    text = text:gsub("`%$([^`\n%$]-)%$`", function(body)
        if not looks_like_math(body) then return nil end
        return keep("`" .. convert(body) .. "`")
    end)
    text = text:gsub("`[^`\n]-`", keep)
    text = text:gsub("%$%$(.-)%$%$", function(body)
        return keep(block(body))
    end)
    text = text:gsub("%$([^%$\n]-)%$", function(body)
        if not looks_like_math(body) then return nil end
        return keep("`" .. convert(body) .. "`")
    end)
    return text
end

return M
