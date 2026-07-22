# Changelog

All notable changes to codewars.nvim are documented here.

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
