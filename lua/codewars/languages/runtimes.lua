--- Per-language test framework and runtime defaults.
---
--- Captured from `/kumite/new`, but they describe CODEWARS LANGUAGES, not
--- kumite: the kata editor needs the same answers. They lived under
--- `codewars.api.kumite` (whose own comment already said "shared with kumite"),
--- which made kata code depend on kumite for data that was never kumite's.
---@class cw.Languages.Runtimes
local M = {}

-- Verified from /kumite/new's defaultFrameworks payload (2026-07-24). Used
-- when starting fresh so it runs with the right test framework; unknown
-- languages fall back to cw-2.
local DEFAULT_FRAMEWORK = {
    ruby = "cw-2", javascript = "cw-2", coffeescript = "cw-2", python = "cw-2",
    php = "phpunit", java = "junit", haskell = "hspec", clojure = "clojure.test",
    csharp = "nunit", elixir = "exunit", elm = "test", erlang = "eunit",
    typescript = "mocha", dart = "test", c = "criterion", cpp = "igloo",
    nasm = "criterion", rust = "rust", julia = "factcheck", crystal = "spec",
    fsharp = "fuchu", ocaml = "ounit", go = "gotest", lua = "busted", nim = "unittest",
    r = "testthat", kotlin = "junit5", scala = "scalatest", groovy = "spock",
    swift = "xctest", sql = "sql", shell = "cw-2", powershell = "pester", solidity = "truffle",
}

-- Verified from /kumite/new's versionInfo payload (2026-07-24): the runtime
-- each language's form preselects (its `default:true` entry). Runs must send
-- this — Codewars' runner otherwise falls back to a legacy runtime (e.g.
-- Python 2.7, where `import codewars_test` fails). Snippet JSON carries no
-- version, so new snippets AND forks rely on this. nil = let the runner decide.
local DEFAULT_VERSION = {
    agda = "2.6.2", bf = "2004", c = "c18_clang-8", cfml = "lucee5.2",
    clojure = "1.8.x", cobol = "3.1-ibm", coffeescript = "1.x", commonlisp = "2.0",
    coq = "8.15", cpp = "c++17_clang-8", crystal = "1.0", csharp = "10.0",
    d = "2.098", dart = "3.3", elixir = "1.15", elm = "0.19", erlang = "26",
    factor = "0.99", forth = "0.7", fortran = "f2008", fsharp = "6.0", go = "1.20",
    groovy = "2.5", haskell = "9.2.5", haxe = "4.0", idris = "1.3", java = "21",
    javascript = "22.x", julia = "1.5", kotlin = "1.3", lambdacalc = "1.0",
    lean = "3.39.1", lua = "5.3", nasm = "2.11", nim = "1.6", objc = "gnustep",
    ocaml = "5.0.0", pascal = "3.2", perl = "5.30", php = "7.x", powershell = "7.2",
    prolog = "8.0", purescript = "0.15", python = "3.11", r = "3.x", racket = "8.1",
    raku = "2020.09", reason = "3.3", riscv = "rv64", ruby = "3.0", rust = "1.66",
    scala = "3.0", shell = "bash", solidity = "0.8.16", sql = "postgres@13.0",
    swift = "5.9", typescript = "4.9", vb = "15.5",
}

---@param lang string
---@return string test framework id
function M.default_framework(lang)
    return DEFAULT_FRAMEWORK[lang] or "cw-2"
end

--- The default runtime version to submit for a run in this language.
---@param lang string
---@return string? languageVersion, or nil to let the runner default
function M.default_version(lang)
    return DEFAULT_VERSION[lang]
end

return M
