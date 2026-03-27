---@class cw.language
---@field slug string
---@field lang string
---@field ft string
---@field comment string

---@type cw.language[]
local langs = {
    { slug = "python", lang = "Python", ft = "py", comment = "#" },
    { slug = "javascript", lang = "JavaScript", ft = "js", comment = "//" },
    { slug = "typescript", lang = "TypeScript", ft = "ts", comment = "//" },
    { slug = "ruby", lang = "Ruby", ft = "rb", comment = "#" },
    { slug = "java", lang = "Java", ft = "java", comment = "//" },
    { slug = "cpp", lang = "C++", ft = "cpp", comment = "//" },
    { slug = "c", lang = "C", ft = "c", comment = "//" },
    { slug = "csharp", lang = "C#", ft = "cs", comment = "//" },
    { slug = "go", lang = "Go", ft = "go", comment = "//" },
    { slug = "rust", lang = "Rust", ft = "rs", comment = "//" },
    { slug = "haskell", lang = "Haskell", ft = "hs", comment = "--" },
    { slug = "clojure", lang = "Clojure", ft = "clj", comment = ";;" },
    { slug = "elixir", lang = "Elixir", ft = "ex", comment = "#" },
    { slug = "swift", lang = "Swift", ft = "swift", comment = "//" },
    { slug = "kotlin", lang = "Kotlin", ft = "kt", comment = "//" },
    { slug = "scala", lang = "Scala", ft = "scala", comment = "//" },
    { slug = "php", lang = "PHP", ft = "php", comment = "//" },
    { slug = "shell", lang = "Shell", ft = "sh", comment = "#" },
    { slug = "lua", lang = "Lua", ft = "lua", comment = "--" },
    { slug = "coffeescript", lang = "CoffeeScript", ft = "coffee", comment = "#" },
    { slug = "sql", lang = "SQL", ft = "sql", comment = "--" },
    { slug = "dart", lang = "Dart", ft = "dart", comment = "//" },
    { slug = "r", lang = "R", ft = "r", comment = "#" },
    { slug = "nim", lang = "Nim", ft = "nim", comment = "#" },
    { slug = "crystal", lang = "Crystal", ft = "cr", comment = "#" },
    { slug = "julia", lang = "Julia", ft = "jl", comment = "#" },
    { slug = "racket", lang = "Racket", ft = "rkt", comment = ";;" },
    { slug = "ocaml", lang = "OCaml", ft = "ml", comment = "(*" },
    { slug = "fsharp", lang = "F#", ft = "fs", comment = "//" },
    { slug = "erlang", lang = "Erlang", ft = "erl", comment = "%" },
    { slug = "fortran", lang = "Fortran", ft = "f90", comment = "!" },
    { slug = "nasm", lang = "NASM", ft = "asm", comment = ";" },
}

return langs
