# Changelog

All notable changes to codewars.nvim are documented here.

## [Unreleased]

### Added
- Custom solution templates. Set `templates.solution.<language>` to a string or
  a function and every new solution buffer starts from it — your imports, your
  helpers, your header. `{{starter}}` is replaced with the code Codewars seeds
  for the kata, so you wrap its graded signature rather than losing it; a
  template without the token replaces the buffer outright and warns once per
  language. An indented token indents every line of the starter to match, so
  `{{starter}}` inside a function body produces code that compiles. Applies to
  `:CW train`, `:CW reset`, language switching, and new kumites. See CONFIGS.md.
- New solution buffers open with the cursor on the last line instead of the
  first. With a template the top of the file is your own boilerplate; the code
  you came to write is at the bottom. A restore-last-position autocmd, if you
  have one, still wins.
- `:CW template on|off` — a global, persisted switch for solution templates,
  plus `:CW template` to report the current state. Turning them off also
  unwraps the kata you have open, and turning them back on re-wraps it, so the
  buffer never disagrees with the setting. The buffer rewrite only proceeds
  when it matches the template exactly; once you have edited the template's own
  lines it says so and changes nothing, rather than guessing which lines to
  delete. Each rewrite is one undo entry.

## [0.3.1] - 2026-08-03

### Added
- `:CW focus skip` — skip the kata Today's Focus is currently serving and open the next one. Use it when a kata is not what you want right now; it advances the trainer queue the same way the website does, and the skipped kata's tab closes once the replacement is on screen.

### Changed
- Re-running `:CW focus` now returns the **same** kata until you solve or skip it. Previously every invocation advanced the trainer queue, so quitting a kata and re-opening Today's Focus silently burned the one you were looking at and served a different one. The queue now advances only when you finish a kata or explicitly skip it.

### Fixed
- Finishing a focus kata now advances the trainer queue, so the next `:CW focus` serves something new. Completing a kata does not move the server's pointer by itself, so the kata you just solved was served again — even after restarting Neovim, because the state lives on Codewars' side. If a queue is already stuck on a solved kata, the next `:CW focus` clears it automatically.
- Today's Focus no longer treats a kata solved in one language as solved in another. Completion on Codewars is per-language, so a kata finished in Python could be silently skipped out of your JavaScript queue without ever being attempted in JavaScript.
- Opening a second kata while one is already open no longer fails with `E95: Buffer with this name already exists`. Every test-case panel was named the same thing, and the error aborted the rest of the kata's setup, leaving it without its console or keymaps.
- Raw HTML embedded in a kata or kumite description now renders instead of showing as literal markup. Codewars descriptions are markdown with HTML mixed in — authors use `<blockquote>` for hints, `<br>` for spacing, `<b>`/`<i>` for emphasis, `<center><img>` for diagrams — and the panel renders as markdown, so those tags appeared verbatim. They are now translated to their markdown equivalents. The translation is an allowlist, never a tag stripper: descriptions are full of generic type parameters that look like tags (`List<string>`, `Dictionary<int, string>`), and anything not on the list is left exactly as written. Fenced blocks, inline code and `<pre>` blocks are held aside so a kata whose sample code contains real HTML keeps it.

## [0.3.0] - 2026-07-25

### Added
- **Kata authoring editor** (`:CW kata open <id|url>`): open a kata you author — the draft `:CW kumite convert` creates — and finish it without leaving Neovim. The editor's five text fields (Complete Solution, Initial Solution, Test Cases, Example Test Cases, Description) each get their own buffer, switched with `g1`…`g5` or `:CW kata pane <name>`, so edits in a hidden pane are never lost. `:CW kata meta` edits name, discipline, estimated rank, tags and allow-contributors; `:CW kata validate` runs the solution against its own test cases through the usual result console; `:CW kata save`, `publish`, `unpublish` and `delete` do the rest, with confirmations on publish and delete. A read-only side panel keeps the metadata, pane list and keys in view. Closing with unsaved edits warns (kata drafts are not stashed yet).
- **Leaderboard** (`:CW leaderboard [category]`, menu `l`): top-500 boards for Overall, Completed Kata, Authored Kata & Translations, and Ranks — position, rank-colored user, clan, and honor/score, scraped live from codewars.com.
- **Kumite browsing** (`:CW kumite`, menu `m`): browse Freestyle Sparring with server paging (page/goto/language keys), open any kumite read-only — including directly from a link via `:CW kumite open <id|url>` — with description, author lineage, and fixture shown in the familiar kata-style layout. Works signed out (public view).
- **Kumite fork & run**: `:CW kumite fork` (or `Ctrl-f` in the browser) turns a kumite into an editable local copy; `:CW test` runs your edited code against its fixture in the familiar result console — no server side effects. Signed-out runs prompt to sign in and then resume. Unsaved edits are stashed to the cache on close so nothing is lost.
- **Start a new kumite**: `:CW kumite new [language]` (menu `m` → New) opens a blank workspace with the language's default test framework — write code and a fixture and run it locally.
- **Save a kumite as a draft** (`:CW kumite save`): saves the current workspace to your codewars.com account — a new draft the first time (a forked/new kumite), an in-place update every time after. Signed-out saves prompt to sign in and then resume.
- **Publish a kumite** (`:CW kumite publish`): after saving, publishes the draft publicly — it runs your code against the fixture on the Codewars runner, and only publishes if the tests pass. Confirms first (publishing is public and can't be casually undone).
- **Unpublish a kumite** (`:CW kumite unpublish`): hides a published kumite again (reversible — publish to re-list it).
- **Convert a kumite to a kata** (`:CW kumite convert`): creates a new kata from the kumite (and hides the kumite); confirms first, then reports the new kata's edit URL to finish authoring on codewars.com. A My Drafts list, draft deletion, and in-editor kata authoring arrive in a later phase.
- **Discoverable keys**: the kumite workspace lists its available commands at the top of the description panel, and the browser now shows a light-blue keybinding box (view / fork / next / prev / go-to-page / language) beside the picker, so it's clear what you can do.

### Fixed
- Kumite runs now submit the language's real runtime version, so `:CW test` no longer fails on Python with `ImportError: No module named codewars_test`. Codewars' runner defaults an unversioned submission to a legacy runtime (Python 2.7, which has no `codewars_test`); the snippet JSON never carries a version, so new kumites and forks now fall back to each language's Codewars-default runtime (verified from `/kumite/new`, e.g. Python `3.11`).
- The kumite fixture buffer can be written with `:w` without `E382: Cannot write, 'buftype' option is set`. Like the code buffer it's now an `acwrite` buffer whose `:w` shows the "runs locally — `:CW test`" hint instead of erroring; editing the fixture also updates the dirty `+` marker.
- `:CW` argument parsing no longer swallows URL positionals containing `=` (e.g. `/kumite/…?sel=…` links) as options.
- Kumite code and fixture buffers now get correct syntax highlighting for every Codewars language: the workspace was setting the buffer's filetype to a file extension (e.g. `py`) instead of the real Neovim filetype (`python`), so only languages where those coincide highlighted. A slug→filetype map now covers 56 languages, and the fixture split uses the fixture's own language (BF/Solidity tests are JavaScript, SQL tests are Ruby, etc.). Highlighting still requires a built-in syntax file or a treesitter parser (`:TSInstall <ft>`) for that language.

## [0.2.0] - 2026-07-22

### Added
- **Choose Today's Focus** (`:CW focus [language] [category]`, Katas menu `f`): the server-side Codewars trainer picks your next kata per category — Fundamentals, Rank Up, Practice and Repeat, Beta — with Random served locally from the cached problem list. Re-running a focus serves a fresh kata, exactly like the website.
- Language and category pickers for the focus flow; the language picker lists every supported language and preselects your default.
- Beta kata open cleanly: unranked kata show a `[beta]` label, and their solutions page explains that community solutions unlock after approval.

### Changed
- All four kata-list dropdowns (sort, language filter, difficulty filter, kata language switch) now share one dropdown component.

### Fixed
- JSON `null` from the Codewars API no longer leaks as `vim.NIL` (crashes on beta-kata ranks/stats; potential first-run language auto-detect corruption).
- `:CW solutions` no longer shows a wrong "complete this kata first" message when a kata simply has no solutions yet.
- Trainer requests are never retried on server errors (a retry would silently skip kata in your focus queue), reject malformed or `success=false` responses, and report an expired session as an auth error instead of "endpoint changed".
- A passing attempt that fails to register on codewars.com is now surfaced (and `:CW submit` blocked until you re-attempt) instead of a false "finalized successfully"; locked solutions pages report the real reason instead of "no community solutions yet".
