local config = require("codewars.config")

local defaults = {
    -- Result popup
    all_passed = "\u{eda9}",
    tests_failed = "\u{f01f8}",
    test_passed = "\u{f058}",
    test_failed = "\u{f06a}",

    -- Picker
    completed = "\u{f058}",
    rank = "●",

    -- Menu
    katas = "\u{f452}",
    stats = "\u{f012a}",
    cookie = "\u{f0198}",
    cache = "\u{f01bc}",
    exit = "\u{f0a48}",
    search = "\u{f002}",
    list = "\u{f452}",
    random = "\u{f074}",
    back = "\u{f0311}",
    update = "\u{f16ec}",
    signin = "\u{f16d6}",
    signout = "\u{f16ea}",
    expand = "\u{f054}",

    -- Language icons
    lang_python = "\u{e606}",
    lang_javascript = "\u{f031e}",
    lang_typescript = "\u{f06e6}",
    lang_ruby = "\u{e791}",
    lang_java = "\u{e738}",
    lang_cpp = "\u{e61d}",
    lang_c = "\u{e61e}",
    lang_csharp = "\u{f031b}",
    lang_go = "\u{e626}",
    lang_rust = "\u{e68b}",
    lang_haskell = "\u{e61f}",
    lang_clojure = "\u{e768}",
    lang_elixir = "\u{e7cd}",
    lang_swift = "\u{f06e5}",
    lang_kotlin = "\u{e81b}",
    lang_scala = "\u{e737}",
    lang_php = "\u{ed6d}",
    lang_shell = "\u{e691}",
    lang_lua = "\u{e826}",
    lang_coffeescript = "\u{e751}",
    lang_sql = "\u{e8b0}",
    lang_dart = "\u{e64c}",
    lang_r = "\u{e881}",
    lang_nim = "\u{e841}",
    lang_crystal = "\u{e7ac}",
    lang_julia = "\u{e80d}",
    lang_racket = "\u{f0627}",
    lang_ocaml = "\u{e84e}",
    lang_fsharp = "\u{e7a7}",
    lang_erlang = "\u{e7b1}",
    lang_fortran = "\u{f121a}",
    lang_nasm = "\u{e637}",
    lang_cobol = "#",
    lang_d = "#",
    lang_prolog = "\u{e7a1}",
    lang_factor = "#",
    lang_groovy = "\u{e775}",
    lang_perl = "\u{e769}",
    lang_lambdacalc = "#",
    lang_powershell = "\u{e86c}",
    lang_elm = "\u{e7ce}",
    lang_reason = "#",
    lang_bf = "#",
    lang_pascal = "#",
    lang_objc = "\u{e84d}",
    lang_haxe = "\u{e7fa}",
    lang_riscv = "#",
    lang_coq = "#",
    lang_forth = "#",
    lang_raku = "#",
    lang_purescript = "\u{e875}",
    lang_agda = "#",
    lang_lean = "#",
    lang_commonlisp = "#",
    lang_idris = "#",
    lang_solidity = "\u{e8a6}",
    lang_vb = "#",
    lang_cfml = "#",
}

local _icons = nil

local function get()
    if _icons then return _icons end
    _icons = vim.tbl_deep_extend("force", defaults, config.user.icons or {})
    return _icons
end

return { get = get }
