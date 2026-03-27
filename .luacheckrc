-- vim: ft=lua

std = "luajit"

globals = {
    "vim",
    "_Cw_state",
}

read_globals = {
    "describe",
    "it",
    "before_each",
    "after_each",
    "assert",
}

ignore = {
    "212", -- unused argument (callbacks, method signatures)
    "542", -- empty if branch (guard clauses)
    "631", -- line too long
}

-- Test files write to package.loaded for mocking
files["test/**"] = {
    globals = { "package" },
    ignore = {
        "211", -- unused variable (destructuring: local res, err = ...)
    },
}

exclude_files = {
    ".github/",
}
