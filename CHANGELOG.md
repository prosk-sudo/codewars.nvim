# Changelog

All notable changes to codewars.nvim are documented here.

## [Unreleased]

### Added
- **Leaderboard** (`:CW leaderboard [category]`, menu `l`): top-500 boards for Overall, Completed Kata, Authored Kata & Translations, and Ranks — position, rank-colored user, clan, and honor/score, scraped live from codewars.com.
- **Kumite browsing** (`:CW kumite`, menu `m`): browse Freestyle Sparring with server paging (page/goto/language keys), open any kumite read-only — including directly from a link via `:CW kumite open <id|url>` — with description, author lineage, and fixture shown in the familiar kata-style layout. Works signed out (public view).
- **Kumite fork & run**: `:CW kumite fork` (or `Ctrl-f` in the browser) turns a kumite into an editable local copy; `:CW test` runs your edited code against its fixture in the familiar result console — no server side effects. Signed-out runs prompt to sign in and then resume. Unsaved edits are stashed to the cache on close so nothing is lost.
- **Start a new kumite**: `:CW kumite new [language]` (menu `m` → New) opens a blank workspace with the language's default test framework — write code and a fixture and run it locally. Saving/publishing to codewars.com and a drafts list arrive in a later phase.
- **Discoverable keys**: the kumite workspace lists its available commands at the top of the description panel, and the browser now shows a light-blue keybinding box (view / fork / next / prev / go-to-page / language) beside the picker, so it's clear what you can do.

### Fixed
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
