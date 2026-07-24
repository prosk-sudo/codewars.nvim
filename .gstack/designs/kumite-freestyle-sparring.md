# Design: Freestyle Sparring (Kumite) for codewars.nvim

**Date:** 2026-07-24 · **Status:** Reviewed — design review (10 decisions) + eng review (5 issues + 10 outside-voice decisions), all resolved · **Author:** Claude (live-verified against codewars.com)

## 1. What Kumite is

Kumite ("freestyle sparring") are user-authored code snippets, not kata. Anyone can
publish a snippet (code + optional test fixture) in any of ~60 languages; others
**fork** it to refactor, golf, or break it, forming a fork tree per snippet. There is
no ranking, no honor from completion, no finalize step — it is a social scratchpad
with a shared runner.

## 2. Verified site mechanics (probed live 2026-07-24, logged-in + logged-out)

### 2.1 Browse list — public, server-rendered, scrapeable
`GET /kumite?language={slug}&page={n}` — no auth required.
- 5 items per page; pagination links go to ~1300 pages; `language` filter is server-side.
- Item markup (verified stable fields): author(s) (`A vs. B` for forks), `<time-ago
  datetime>`, title + canonical link `/kumite/{parentId}?sel={snippetId}`,
  `<pre lang><code>` full snippet code, Diff tab, Fork link, Discuss + count.

### 2.2 Snippet data — clean JSON API (cookie auth)
`GET /api/v1/code-snippets/{id}` returns the full model:

```
id, title, description, language, testFramework, testLanguage,
code, fixture, package, state ("published"/draft), parentId,
publishedAt, validFixture, publishedForks, tags,
user { id, username, url }, url, editUrl, newUrl, runResult, discourse { … }
```

The detail page embeds one `data-view-data-path="/api/v1/code-snippets/{id}"` node
per fork in the tree. v1 uses only the single-snippet JSON; the tree is documented
for the post-v1 Forks picker (see NOT in scope).

### 2.3 Running code — existing runner, directly reusable
1. `POST /api/v1/runner/authorize` → short-lived bearer token
2. `POST https://runner.codewars.com/run` with `{ language, code, fixture,
   testFramework, languageVersion, setup, relayId }`

Kumite has **no notify / no finalize**. Local runs are side-effect-free.
`attempt.submit(...)` works as-is; `relayId` = snippet id.

### 2.4 Create / fork / edit — form model mapped; mutation contract UNVERIFIED
`/kumite/new` (auth) embeds the complete form model:
- Fields: `code_snippet[parent_id, title, description, package, code, setup_code,
  fixture, example_fixture, test_framework, user_tags, language, language_version,
  secret, code_challenge_id, forked_from_challenge]`
- Per-language metadata: `supportedLanguages` (60+), `versionInfo`,
  `defaultFrameworks`, `tddLanguages`.

**Contract-verification step (P3 gate — eng review D7, expanded from a single
draft probe).** Before any P3 code or spec is written, a consented live session
must establish:
1. **Encoding** — whether `POST /kumite` accepts JSON or requires form-encoding
   (our HTTP layer currently forces `application/json` and JSON-encodes bodies —
   `api/utils.lua:50`, `api/headers.lua:24`; a form-encoded variant may be needed).
2. **Draft-id retrieval** — how the created draft's id is returned (JSON body vs
   Rails redirect `Location`; the current layers discard response headers — if the
   id arrives via redirect, `api/utils`/`api/page` must expose status + headers).
3. **Update, publish, and delete** semantics — all four verbs, not just create.
4. **Field mapping table** — JSON keys ↔ form keys resolved explicitly
   (`package` vs `setup_code`, `fixture` vs `example_fixture`, `testLanguage`,
   which value feeds runner `setup`), written into this doc.
5. **`secret` round-trip** — saved drafts must resubmit the observed `secret`
   value; omitting it may flip a snippet's visibility.
P3 request-shape specs are written FROM the verified contract, never before it.

### 2.5 Auth summary
| Surface | Auth |
|---|---|
| List/browse pages | none |
| `GET /api/v1/code-snippets/{id}` | cookie |
| Runner authorize/run | cookie (existing) |
| Create/fork draft-save/publish | cookie + CSRF (existing) |

## 3. UX Design (design review D4–D13 + eng review D2–D17, all resolved)

### 3.1 Menu placement — top-level, entries mount per phase (D4; eng D8)

```
main:  k Katas · s Statistics · l Leaderboard · m Kumite ▸ · i Cookie · c Cache · qa Exit

kumite page:   P1 ships:  b Browse            ← Back
               P3 adds:   n New    d My Drafts
```

Menu entries appear only when their phase ships — no dead buttons. Logged out,
the menu remains the sign-in page (unchanged); kumite's public browse is reachable
via `:CW kumite` command only (eng D11).

### 3.2 The browser (telescope picker) — D11 + eng D15/D17

```
┌ Kumite · python · page 3 ─────────────────────────────────────────────┐
│ > compareing(i dunno…)   AdisaOyo vs umlittlethings · python · 26d ago│
│   …(5 rows — one server page)                                         │
├───────────────────────────────────────────────────────────────────────┤
│ <CR> view · <C-f> fork (local) · <C-n>/<C-p> page · <C-g> goto ·      │
│ <C-l> language                                                        │
└───────────────────────────────────────────────────────────────────────┘
```

- Entry: `title · author (vs parent-author) · lang · age`; page number lives in
  the prompt title.
- `<C-n>`/`<C-p>` fetch next/previous server page (`<C-p>` inert on page 1);
  `<C-g>` prompts for a page number (clamped to the last known page);
  `<C-l>` reopens the language dropdown and **resets to page 1** (a persisted page
  crossing languages would land on meaningless empty pages).
- Language + page persist across picker reopens; async guard: page/language
  fetches carry a generation counter — only the latest generation renders (eng D14).
- `:CW kumite open <id|url>` (P1) opens a kumite directly — the `:CW train
  <slug|url>` pattern applied to `/kumite/{id}` links (eng D17).
- No search/sort in v1 (D13; site parity).

### 3.3 The workspace — one kata-style tab for all states (D5)

Code buffer primary; description and fixture splits appear only when they have
content or are opened; result console after Run. Buffer/tab title always shows
`Kumite · {title} · {lang} · {State}[ +]`. The description split header carries
author, publish date, `fork of: {parent}`.

```
┌─ description split ──┬─ Kumite · Big number · java · Published (read-only) ──┐
│ Return the bigger    │ public class BiggerNum { … }                          │
│ integer              ├─ fixture (testcase split) ────────────────────────────┤
│ by tarkhnas · 2018   │ import org.junit.Test; …                              │
│ fork of: — (root)    │                                                       │
└──────────────────────┴───────────────────────────────────────────────────────┘
```

Read-only states set the buffer non-modifiable; edit attempts log
`This kumite is read-only — :CW kumite fork to edit a copy.`

**Unsupported-language fallback (eng D13):** kumite exist in 60+ languages, the
plugin configures 32. Unknown language → plain-text filetype, generic icon;
**view and run always work** (the runner is server-side); fork/create are
restricted to configured languages with a clear message.

### 3.4 Editor state model — six states, kept per eng D16

| State | Editable | Server object | Primary action |
|---|---|---|---|
| `published_view` | no | published (someone's) | Run |
| `local_new` | yes | none | Test |
| `local_fork` | yes | none (carries `parent_id`) | Test |
| `server_draft` | yes | draft (yours) | Test / Save |
| `saving` / `publishing` | locked | in flight | — |
| `published` (yours) | no | published | Run |

Implemented as a **pure module** `lua/codewars/kumite/state.lua` (eng D3):
transition table + `step(state, action) → new_state | error_string`; the
state-aware rejection messages live in the table. Fork is a **local transition**
— nothing exists on codewars.com until explicit save/publish (D6).

### 3.5 Workflows (D10) — with eng corrections

- **New (P3):** auth gate → language dropdown (configured languages only) → title
  input (required) → workspace in `local_new` with metadata defaults preloaded.
- **Fork (P2):** auth gate → fetch full parent → `local_fork`, everything
  inherited from the parent (no metadata subsystem needed — eng D8).
- **Save Draft (P3):** validate → submit → failure: stay editable+dirty, error
  names cause → success: `server_draft`, registry updated. Single-flight per
  workspace; **create only when no `draft_id`, else update** (idempotent retries,
  eng D14).
- **Publish (P3):** validate → confirm dialog (Cancel default):
  > Publish "{title}" publicly? This cannot be returned to draft.
  → success: `published`, read-only. Mandatory.

Auth gate = closure through the existing `cmd.cookie_prompt(cb)`
(command/init.lua:463) — **no pending-action store** (eng D2). Sign-in success
runs the wrapped action; cancel drops it. `utils.auth_guard` stays for
non-resumable paths.

**Field-to-surface contract:** title → create-time input / `:CW kumite title`;
description → description split (via content-provider parameterization, T13);
code → main buffer; fixture → testcase split; language → chosen pre-workspace,
immutable; version/framework/tags → `:CW kumite settings` popup;
`setup_code`/`package`/`example_fixture` → preserved per the verified mapping
(2.4), not editable in v1; `secret` → round-tripped, never exposed.

### 3.6 Interaction state table (D7) — eng-corrected rows

| Surface / event | What the user sees |
|---|---|
| Browser opening | `Loading kumite…`; picker opens on data |
| Empty page (valid) | `No published kumite on this page.` — distinct from drift |
| Parse drift | honest "Codewars may have changed their HTML format" warning — never an empty list |
| Network failure | current surface stays; retryable error |
| Logged out | menu = sign-in page (unchanged); `:CW kumite` browse works; `<CR>` shows code-only view from list data; Run/Fork/New → cookie prompt, action resumes via closure on success |
| Save/publish failure | buffer stays editable + dirty; error names the cause |
| In-flight save/publish | repeated commands rejected with state-aware message |
| **Dirty close (eng D10 — hybrid)** | split content already lives in the model (T15); on close of a dirty workspace: prompt `Save Draft / Discard / Reopen workspace`; plugin exit (`stop()`) checks dirty kumite before `qa!`; **auto-stash safety net**: dirty models stash to a local file on unmount, so `:qa!` and crashes lose nothing — stashes surface in My Drafts as local entries |
| Wrong-state command | names the state — never `No current kata found` |

Async guards (eng D14): every workspace callback validates its buffers first;
picker fetches are generation-checked; save/publish single-flight per workspace.

### 3.7 Drafts — honest scope (D9; eng D6/D4/D12)

`:CW kumite drafts` + menu `My Drafts` (P3). Picker title: **"Drafts saved from
Neovim"** — it lists drafts created through the plugin (no site endpoint exists to
enumerate account drafts). Durable registry entries:
`{draft_id, title, language, parent_id, saved_at, user_id}` — **account-scoped**:
only entries matching the current cookie's user render.

Behavior: **registry-first, async validation** — rows render instantly from
registry data; per-draft JSON fetches run concurrently and update marks as they
land. Observed states relabel rows: `draft` → editable; `published` (from the
website meanwhile) → labeled, opens `published_view`, removal offered;
deleted → marked, removable; **auth failure → "sign in to check", never a
deletion mark**. Local stash entries (3.6) also appear here.

### 3.8 Keymaps (D12)

| Where | Key | Action |
|---|---|---|
| picker | `<CR>` / `<C-f>` | view / local fork |
| picker | `<C-n>` / `<C-p>` / `<C-g>` | next / prev / goto page |
| picker | `<C-l>` | language (resets to page 1) |
| workspace | `g?` | command help filtered to kumite |
| workspace | existing toggles | description/fixture/console splits |
| anywhere | ex commands | `:CW test`, `:CW kumite open/fork/save/publish/title/settings/drafts` — work from any window of the kumite tab |

### 3.9 Journey storyboard

| Step | User does | User feels | Design support |
|---|---|---|---|
| 1 | `m` in menu (or `:CW kumite`) | curious | top-level entry; command works signed out |
| 2 | browses / jumps pages | oriented | page in title, `<C-g>` addressable |
| 3 | opens one (or a shared link) | safe | read-only marked; `:CW kumite open <url>` |
| 4 | `:CW test` | engaged | familiar console, no side effects |
| 5 | forks | playful | local copy, nothing public |
| 6 | edits + tests | in flow | dirty `+`; close guarded + stashed |
| 7 | saves draft (P3) | secure | reachable in My Drafts, honestly labeled |
| 8 | publishes (P3) | deliberate | confirm dialog, Cancel default |
| 9 | sees it read-only | accomplished | state flip confirms live |

## 4. Architecture (eng-corrected)

| Module | Role | Pattern followed |
|---|---|---|
| `api/kumite.lua` | list scraper, snippet JSON fetch, contract-verified mutation POSTs (P3) | `api/leaderboard.lua` scrape via `api/page.fetch`; `api/utils.post` — extended for status/headers if the probe requires (2.4) |
| `codewars/kumite/state.lua` | **pure** 6-state machine: transition table + step() + rejection strings (eng D3) | `theme.rank_hl` / `empty_reason` pure-logic precedent |
| `codewars-ui/kumite.lua` | workspace mount, current state, dirty tracking, close guard + stash | kata shell — kumite-specific unmount (no `force = true` on dirty) |
| `codewars-ui/split/description.lua` | **content-provider parameterization** (T13): markdown body + custom header lines + editable flag — kata rendering unchanged | existing split, refactored not duplicated |
| console / run dispatch | **workspace-aware dispatch** (T14): `:CW test` resolves kata OR kumite workspace; console takes a run callback instead of constructing the kata Runner | `_Cw_state` extension; regression-spec'd |
| split content sync | **model sync on change/unmount** (T15): description/fixture edits survive split toggles | fixes verified remount-repopulation loss |
| `command/init.lua` | `cmd.kumite` nested subcommands incl. `open <id|url>`; auth gate closure via `cookie_prompt(cb)` | `cookie`/`cache` nested tables; `parse_slug` precedent |
| `cache/kumite_drafts.lua` | durable, account-scoped registry + local stashes | `cache/completed.lua` pattern |

Messaging: existing log idioms + honest drift wording. Icons FA-classic;
highlights `codewars_*` groups.

## 5. Phasing (eng D8 — rephased)

- **P1 — read:** menu entry (Browse only), browser with paging/goto, `:CW kumite
  open <id|url>`, workspace in `published_view`, unsupported-language fallback,
  state/empty/error rows for browse/view. Zero mutation risk.
- **P2 — fork + run:** T13/T14/T15 enabling refactors, `local_fork` editing
  (everything inherited from parent — no metadata subsystem), dirty tracking +
  hybrid close guard + stash, runner wiring, auth-resume closures. Zero server
  writes. (`local_new` is NOT in P2.)
- **P3 — write:** starts with the **contract-verification session** (2.4, consented);
  then metadata capture (title/settings), `local_new` + New menu entry, Save
  Draft, Publish with confirm, drafts registry + My Drafts. Gated on the probe.

## 6. Risks & mitigations

1. **Mutation contract unverified** — P3 gated on the full contract session (2.4);
   P1/P2 unaffected. Request-shape specs written from probe results only.
2. **List-scrape drift** — fixture-based specs + honest drift messages.
3. **Runner `relayId` semantics** unconfirmed — worst case omit it.
4. **Kata-shell coupling** — T13/T14/T15 touch shipped kata paths; each carries a
   CRITICAL regression spec (kata behavior unchanged).
5. **Async races** — generation counters, buffer-validity checks, single-flight
   saves with draft-id idempotency (eng D14).

## 7. Testing strategy

- `test/codewars/kumite_spec.lua`: `parse_list_html` against saved live HTML
  (fork/solo/pagination, drift → {}); snippet JSON luanil normalization; command
  routing incl. `open <id|url>` parsing and state-aware rejections; draft registry
  read/write/staleness + account scoping + published-elsewhere relabel + auth-fail
  distinct state.
- `codewars/kumite/state.lua`: full transition-matrix spec — pure, zero UI stubs.
- P2: run-wrapper spec (stubbed `attempt`); dirty-close hybrid spec (prompt paths +
  stash-on-unmount); logged-out code-only view spec; stale-generation picker spec;
  **CRITICAL regression specs (iron rule): kata description split renders unchanged
  after T13; `:CW test` on a kata unchanged after T14; kata split toggles unchanged
  after T15.**
- P3: request-shape specs FROM the verified contract (never before it); empty-title
  rejection; publish confirm Cancel ⇒ zero network calls; settings round-trip
  preserves mapped fields byte-identically; secret round-trip; auth-resume closure
  spec; save idempotency (retry updates, never duplicates).

## 8. NOT in scope (v1)

| Cut | Rationale | Later path |
|---|---|---|
| Fork-tree UI | no v1 screen consumes it; removes a scrape-drift class | "Forks" picker from the viewer |
| Diff-vs-parent view | TUI diff rendering is its own design problem | `:diffthis` manual stopgap |
| Editing published snippets | unverified public mutation flow | post-contract-verification |
| Search/sort in browser | site has none — paged latest-first is parity (D13) | if the site grows one |
| Listing website-created drafts | no site endpoint exists; My Drafts is honestly labeled plugin-saved | if an endpoint appears |
| Discourse (comments/votes) | pre-existing decision | separate feature |
| `secret` visibility control | semantics unverified; value round-tripped, never exposed | after verification |

## 9. What already exists (reuse inventory — eng-corrected)

Directly reusable: kata tab shell, testcase split, result console *chrome*,
telescope pickers + shared dropdown, `cookie_prompt(cb)` continuation hook,
`api/page.fetch`, `api/utils` JSON/auth/CSRF + luanil policy, durable-cache
pattern, honest-messaging idioms, FA-classic icons, `codewars_*` highlights,
`parse_slug` URL parsing.

Reusable **after named refactors** (eng D9 — the plan owns these): description
split (T13 content provider — today it hardcodes kata rank/stats/tags),
console→runner coupling and `:CW test` dispatch (T14 — today kata-only via
`_Cw_state.katas`), split content persistence (T15 — today remount repopulates
from the stale model).

## Implementation Tasks
Synthesized from design + eng review findings. Checkbox as you ship.

- [ ] **T1 (P1, human: ~1d / CC: ~30min)** — api — `api/kumite.lua`: list scrape + snippet JSON fetch + unsupported-language-safe normalization
- [ ] **T2 (P1, human: ~1d / CC: ~30min)** — picker — browser with server paging, `<C-g>` goto (clamped), language switch resets page, generation-guarded fetches
- [ ] **T3 (P1, human: ~2d / CC: ~45min)** — workspace — pure `kumite/state.lua` + kata-style tab in `published_view` (state title, social header, read-only guard, language fallback)
- [ ] **T4 (P1, human: ~2h / CC: ~10min)** — menu — top-level `m Kumite` page, Browse only at P1; per-phase entry mounting
- [ ] **T5 (P1, human: ~2h / CC: ~15min)** — command — `:CW kumite` + `:CW kumite open <id|url>` (parse_slug pattern) + completion
- [ ] **T6 (P1, human: ~2h / CC: ~10min)** — docs — `g?` kumite help, COMMANDS.md, README
- [ ] **T7 (P2, human: ~1d / CC: ~25min)** — refactor — description split content-provider parameterization + CRITICAL kata regression spec (eng D9a)
- [ ] **T8 (P2, human: ~1d / CC: ~30min)** — refactor — workspace-aware `:CW test` dispatch + console run-callback + CRITICAL kata regression spec (eng D9b)
- [ ] **T9 (P2, human: ~1d / CC: ~25min)** — refactor — split-content sync into model on change/unmount + CRITICAL kata regression spec (eng D9c)
- [ ] **T10 (P2, human: ~2d / CC: ~40min)** — workspace — `local_fork` editing, dirty tracking, hybrid close guard (prompt + auto-stash + `stop()` check) (eng D10)
- [ ] **T11 (P2, human: ~1d / CC: ~20min)** — runner — kumite run wrapper via `attempt.submit` (no notify/finalize)
- [ ] **T12 (P2, human: ~2h / CC: ~10min)** — auth — resume closures via `cookie_prompt(cb)`; cancel drops action (eng D2)
- [ ] **T13 (P3, human: ~half day / CC: ~30min live)** — probe — **contract-verification session** (encoding, id retrieval, update/publish/delete, field mapping, secret round-trip); results written into §2.4 (eng D7)
- [ ] **T14 (P3, human: ~2d / CC: ~45min)** — workflows — metadata capture (title/settings), `local_new`, Save Draft (single-flight, idempotent), Publish confirm; specs from the verified contract
- [ ] **T15 (P3, human: ~1d / CC: ~30min)** — drafts — account-scoped registry, "Drafts saved from Neovim" picker (registry-first async validation, honest relabels), stash surfacing (eng D6/D12)

## Failure modes (per new codepath)

| Codepath | Realistic failure | Test? | Handled? | User sees |
|---|---|---|---|---|
| List scrape | markup drift | yes (drift spec) | yes | honest drift warning |
| Snippet fetch | 401 expired cookie | yes | yes (auth err path) | sign-in message |
| Picker paging | stale slow response | yes (generation spec) | yes | only latest page renders |
| Run | runner timeout | yes (wrapper spec) | yes | console error, retryable |
| Split toggle | edit loss on remount | yes (T9 spec) | yes (model sync) | nothing — edits survive |
| Dirty close | `:qa!` / crash | yes (stash spec) | yes (auto-stash) | stash in My Drafts |
| Save Draft | timeout then retry | yes (idempotency spec) | yes (draft-id update) | one draft, not two |
| Publish | success=false / rejection | yes | yes (stays dirty) | named cause, work kept |
| Drafts picker | draft published elsewhere | yes (relabel spec) | yes | honest relabel |
No critical gaps: every failure mode has a test, handling, and a visible message.

## Worktree parallelization

| Step | Modules touched | Depends on |
|---|---|---|
| T1 api | `api/` | — |
| T2 picker | `picker/` | T1 |
| T3 workspace+state | `kumite/`, `codewars-ui/` | T1 |
| T4-T6 menu/command/docs | `renderer/`, `command/` | T3 |
| T7-T9 refactors | `codewars-ui/split/`, `layout/`, `command/` | — (independent of T1-T3) |
| T10-T12 editing | `codewars-ui/` | T3, T7-T9 |
| T13-T15 write | `api/`, `cache/`, `command/` | T10, probe |

Lanes: **A:** T1 → T2/T3 → T4-T6 (P1). **B:** T7 → T8 → T9 (refactors, independent).
Launch A and B in parallel worktrees; both touch `command/` lightly at their ends —
merge A first, rebase B. Then sequential: T10-T12, then T13-T15.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | (outside voices absorbed below) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (PLAN) | 5 issues (2 arch, 1 quality, 4 test gaps as 1, 1 perf) + 10 outside-voice decisions, all resolved |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | CLEAR (FULL) | score: 4/10 → 9/10, 10 decisions, narrow-terminal audit run |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CODEX:** ran twice — design critique (8 findings, absorbed into design decisions D4–D13) and outside-voice plan challenge (16 findings: 10 confirmed and adopted via eng D7–D15/D17, 2 folded, 1 self-resolved; state-machine dissent rejected per eng D16, scope dissent declined per standing eng D1).
- **CROSS-MODEL:** design-stage voices agreed on every litmus check; plan-stage Codex challenge overturned four reuse/phasing assumptions Claude's review had accepted (form encoding, console coupling, split edit-loss, WinClosed semantics) — all verified against source before adoption.
- **VERDICT:** DESIGN + ENG CLEARED — ready to implement (P1 first; P3 gated on the §2.4 contract-verification session).

Note: `gstack-review-log` rejects all writes on this machine (known CLI bug); this
report and the session transcript are the review record.

NO UNRESOLVED DECISIONS
