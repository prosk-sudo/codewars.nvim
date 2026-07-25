--- Codewars language slug → Neovim filetype (the real filetype *name*, not
--- the file extension config.langs stores). Kata open real files so their
--- filetype is auto-detected; kumite buffers are scratch (buftype=acwrite)
--- so we must set the filetype ourselves, for every language codewars
--- supports — not just the 32 the plugin configures for training.
---
--- Whether highlighting then appears depends on Neovim having a syntax file
--- (built-in for many: c/cpp/java/python/ruby/perl/php/sql/haskell/lisp/…)
--- or a treesitter parser (`:TSInstall <ft>` for rust/go/typescript/…).
--- Setting the correct filetype is the necessary enabler either way.
local M = {}

--- slug → filetype. Absent ⇒ no highlighting available (e.g. brainfuck,
--- lambda calculus have no Neovim grammar), left as plain text.
M.map = {
    python = "python", javascript = "javascript", typescript = "typescript",
    ruby = "ruby", java = "java", cpp = "cpp", c = "c", csharp = "cs",
    go = "go", rust = "rust", haskell = "haskell", clojure = "clojure",
    elixir = "elixir", swift = "swift", kotlin = "kotlin", scala = "scala",
    php = "php", shell = "sh", lua = "lua", coffeescript = "coffee",
    sql = "sql", dart = "dart", r = "r", nim = "nim", crystal = "crystal",
    julia = "julia", racket = "racket", ocaml = "ocaml", fsharp = "fsharp",
    erlang = "erlang", fortran = "fortran", nasm = "nasm", cobol = "cobol",
    d = "d", prolog = "prolog", factor = "factor", groovy = "groovy",
    perl = "perl", powershell = "ps1", elm = "elm", reason = "reason",
    pascal = "pascal", objc = "objc", haxe = "haxe", coq = "coq",
    forth = "forth", raku = "raku", purescript = "purescript", agda = "agda",
    lean = "lean", commonlisp = "lisp", idris = "idris2", solidity = "solidity",
    vb = "vb", cfml = "cf", riscv = "asm",
}

--- Some fixtures are written in a different language than the solution
--- (BF / lambda calc / Solidity tests are JavaScript, SQL tests are Ruby,
--- NASM / RISC-V tests are C). Codewars exposes this as testLanguage; for a
--- fresh kumite we derive it from the solution language.
M.test_lang = {
    bf = "javascript", lambdacalc = "javascript", solidity = "javascript",
    sql = "ruby", nasm = "c", riscv = "c",
}

--- Filetype for the solution code buffer.
---@param slug string
---@return string? filetype # nil when no grammar exists for the language
function M.code(slug)
    return M.map[slug]
end

--- Filetype for the fixture (test) buffer. Prefers the server's
--- testLanguage, then the known solution→test-language mapping, then the
--- solution language itself.
---@param slug string
---@param test_language string? codewars testLanguage slug, if known
---@return string? filetype
function M.test(slug, test_language)
    local tl = test_language or M.test_lang[slug] or slug
    return M.map[tl] or M.map[slug]
end

return M
