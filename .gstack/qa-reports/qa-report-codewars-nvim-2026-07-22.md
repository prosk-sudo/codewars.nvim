# QA Report — codewars.nvim, feat/todays-focus (v0.2.0)

**Date:** 2026-07-22 · **Mode:** diff-aware (headless nvim against live Codewars API; no web UI — browser harness N/A for a TUI plugin)
**Status:** PASS — live matrix green after user re-saved the session cookie. 0 issues found, 0 fixes needed.

## Verified live (headless nvim, real Codewars API)

- **Auth error path (unauthenticated run):** trainer call with no cookie → HTTP 401 surfaced as `auth=true` + "Session expired or invalid. Run :CW cookie to re-authenticate." No traceback.
- **fundamentals** → `binary-addition` (OK)
- **rank_up** → `battleship-field-validator` (OK)
- **practice_and_repeat** → `remove-anchor-from-url` (OK — and it's a previously-attempted kata in the user's solutions dir, confirming the category's server semantics)
- **beta** → `arithmetic-sequence-find-hidden` (OK)
- **Beta kata full mount:** `Kata:new():mount()` on the live beta kata — 4 windows, 6 buffers, zero logged errors, description header renders `# Arithmetic Sequence - find hidden [beta] (58/372, 15.6%)`. The v0.1 crash (theme/init.lua:121 userdata compare) is confirmed fixed on live data.

- **Focus → Random (after user ran `:CW cache update`):** `random_for_lang("python")` returned a kata from the fresh cache, and the full `cmd.focus python random` flow mounted `# Snail Length [6 kyu] (132/519, 25.4%)` — 4 windows, 6 buffers, zero logged errors. Also live-confirms the ranked-kata header (rank label + stats) alongside the beta case.

## Skipped

- None — full live matrix complete.

## Non-live coverage (already green this branch)

Full plenary suite exit 0 (incl. 5 new spec files covering trainer parse/error paths, focus command flows, dropdowns, theme rank guards); luacheck 0/0. Pre-landing review + adversarial passes: 14 findings, all fixed (see PR #1).

**Health score:** not computed — only 1 of the live test matrix could run unauthenticated.
