# Changelog

All notable changes to codewars.nvim are documented here.

## [0.3.3] - 2026-08-26

### Added
- Math in kata descriptions is rendered as readable text instead of raw
  LaTeX. `$…$`, `$$…$$` and ```` ```math ```` blocks (what Codewars typesets
  with KaTeX) are translated: `\frac{x_A + x_B + x_C}{3}` → `(x_A + x_B + x_C)/3`,
  `x^2` → `x²`, `a_{i+1}` → `aᵢ₊₁`, `\sqrt{n}` → `√n`, Greek letters,
  `\le \ne \cdot \times \sum \infty \in \to …` → `≤ ≠ · × ∑ ∞ ∈ →`,
  `\mathbb{N}` → `ℕ`, and `\\` starts a new line. Inline math becomes a code
  span and block math a fenced block, so markdown never mangles it; anything
  the translator does not know is kept as written. A `$` inside code, or a
  price like `$5`, is left alone.

### Changed
- The problem list no longer expires under you. It is trusted for 30 days
  (was 7), and even past that `:CW list` and `:CW random` open the list you
  have immediately and rebuild it in the background — the minutes-long,
  rate-limit-prone rebuild never blocks you again unless nothing is cached
  at all. `:CW doctor` shows the list's age. The completed-kata list keeps
  its own one-day refresh (`cache.completed_interval`) so kata you solve on
  the website still show as completed promptly; if you had set
  `cache.update_interval` to shorten that, move the value to the new option.

### Fixed
- `:CW list difficulty=` and `order=` behave like the picker's own menus.
  `<Tab>` after `difficulty=` or `order=` completes the value without erasing
  what you typed (`difficulty=8,` offers `difficulty=8,7`, …). `difficulty=`
  is applied as the picker's own rank filter — one rank or a set — so
  `Ctrl-d` shows it selected with the real per-rank counts instead of "All
  ranks" and zeros, and can widen back to all ranks; a plain `:CW list`
  keeps whatever you last chose in the menus. `order=` was silently ignored
  for the cached list and accepted values it could never honour (the cached
  catalogue has no dates, and "popularity" would only have reproduced
  easiest-first); it now selects the picker's sort mode — `shuffle`, `name`,
  `satisfaction`, `hardest`, `easiest` — and rejects anything else, including
  an empty or doubled value. `Ctrl-s` offers the same five, and both they and
  the rank counts work in `:CW completed` too.
- `:CW train "remove first and last character"` works: the `:CW` command was
  registered with `-bar`, under which a double quote starts an Ex comment, so
  everything from the quote on was thrown away before the plugin saw it.
  `:CW` can no longer be chained with `|`; quote a title instead.
- Smaller fixes across the UI: the kata list's "language unavailable" warning
  judges each kata against the language you are filtering by, not the default;
  kumite ages in the list are computed in UTC (they were off by your timezone);
  a runner reply arriving after the console was closed is ignored instead of
  raising; a passing result with an empty `reason` no longer shows an empty
  "Error" section; a confirmation prompt containing a token wider than the box
  (a URL) is wrapped instead of overflowing; `:CW` no longer errors when the
  remembered menu buffer is gone but its window is not; and closing a kata no
  longer leaves a stray scratch buffer behind.
- `:CW doctor` checks more of what the parsers return: the kumite-list check
  now verifies id, author, language and pagination, and the kata-edit check
  verifies the test fixture is extracted.
- `:CW submit` is only unlocked by a real `:CW attempt`. A passing `:CW test`
  runs against the editable test-cases pane, so it no longer counts; submit
  waits until Codewars has registered the attempt instead of finalizing a
  moment too early; and an attempt whose reply arrives after you switched
  language is credited to the session it ran on, not the new one. If a
  language switch fails half-way, every session field (ids, fixtures,
  file) is put back and the previous buffer is shown again, instead of
  leaving a mix of the old buffer and the new session.
- `:CW train` accepts a kata title the way COMMANDS.md always said it did:
  `:CW train Unique In Order python` and `:CW train "Unique In Order"` both
  work (a trailing word that names a language is the language; quotes keep a
  title together), and an unknown language after a slug is reported as
  `Unknown language: …` instead of an assertion from deep inside the kata
  path. `:CW list difficulty=abc` reports the bad value instead of raising.
- Solution comments keep generics: `List<string>`, `Map<K, V>` and
  `ArrayList<>` used to be stripped as if they were HTML tags. Numeric HTML
  entities (`&#8217;`, `&#xA9;`) in clan names and comments are decoded.
  One-line community solutions of ten characters or fewer are no longer
  dropped from the solutions list.
- A kata description whose `<pre>` block contains inline code no longer shows
  a literal `CWMD1` placeholder where the code should be.
- Reading your profile from the dashboard no longer fails on accounts whose
  data contains an escaped quote before a closing parenthesis.
- The completed-kata cache can no longer be quietly wrong. Solving a kata
  while the cache is missing or expired records it without stamping a
  one-item list as a complete, fresh cache; a refresh that gets a reply it
  does not understand keeps the cached list (and says so) instead of
  overwriting it with an empty one; a kata you solved while a background
  refresh was running stays marked complete; a refresh that fails passes the
  error to the caller rather than pretending you have no completed kata; and
  the "Fetched N kata details" message counts only the ones that worked,
  with a rate-limit hint when that is why some failed. The problem-list
  cache is left untouched when every search page comes back empty (site
  markup drift), instead of being replaced by an empty fresh cache.
- Solution templates round-trip exactly. A function template that builds
  its text from `ctx.starter` is now recognised by `:CW template on/off`
  (it used to be reported as having no `{{starter}}`); blank lines at the end
  of your code survive `on` → `off`; whitespace-only lines come back with
  their spaces; and a template that is nothing but `{{starter}}` never claims
  to match a buffer, so `:CW template off` cannot cut lines from it.
- The seeded NASM kumite fixture compiles: it is a C (criterion) file and now
  starts with a C comment instead of a NASM `;` comment.
- `lang = false` in `setup()` is treated as "not set" instead of becoming the
  default language; a kata whose API reply carries `testLanguage = ""` gets
  the test pane's proper filetype (NASM/SQL/etc. map to their test language).
- Kumite editing follows its state machine everywhere. Buffers lock while a
  save or publish is in flight and unlock again afterwards; `:CW kumite run`
  refuses to run mid-save; `:CW kumite convert` refuses someone else's kumite
  (fork it first) and refuses while you have unsaved edits, so the kata is built
  from what you actually saved; renaming a published kumite through the
  convert retry is refused with instructions instead of silently failing; a
  fork always gets a test-fixture pane; and a save or publish whose reply
  arrives after the workspace was closed no longer errors on the dead buffer.
- Kata editor: adding a language and immediately saving or publishing again no
  longer races the id read-back that would have dropped the new language.
- Saving a fetched **private** kumite no longer flips it public: the snippet's
  `secret` flag is read from the API and re-sent on save, as the save code
  always claimed it was. A kata save that Codewars answers with a JSON
  refusal (`success: false`) is now reported as rejected, with the server's
  own message, instead of "saved"; a rejected publish shows the real reason.
- Closing a kata no longer loses work. Unsaved solution edits are written to
  the solution file before the buffer is removed (it used to be force-deleted,
  bypassing Neovim's unsaved-changes protection — including via `:CW focus
  skip`); hiding the Test Cases pane keeps the buffer, so toggling it no longer
  throws away edited test cases and `:CW test` runs what you wrote; buffers left
  behind by language switches are cleaned up with the kata instead of leaking
  for the session; and opening the same kata in a second language no longer
  disables the first one's cleanup.
- Bare `:CW` no longer turns the buffer you had open into the dashboard: a real
  file or unsaved text is left alone and the menu gets its own scratch buffer.
- Switching languages twice in quick succession applies the later choice, not
  whichever reply arrived last; a kata already open in the language a mount
  falls back to is reused instead of opened twice; solution paths with spaces
  open correctly.
- Switching accounts (`:CW cookie` with a different session, or `:CW cookie
  delete`) now drops everything the previous account owned: the completed-kata
  list and details, every cached training session (project/solution ids), the
  detected username, the picker's completed set, and the remembered focus
  kata. Previously only the solutions cache was dropped, so the new account
  could attempt against the old account's session ids, see its kata as
  completed, and stay "Signed in as" the old name.
- `:CW template on` now puts the cursor at the end of your starter code after
  re-wrapping the buffer — not wherever it happened to be (usually inside the
  template's preamble), and not the end of the file, which is the template's
  suffix when there is content after `{{starter}}`.

## [0.3.2] - 2026-08-23

### Added
- Open a kata by its title, not just its slug. `:CW train` and the menu accept
  the name the way the site shows it — "Unique In Order", or "Unique in Order
  (6 kyu)" copied straight from a list — and build the slug the way Codewars
  does.
- Community solutions now show their votes and comments. A one-line box under
  the code carries each solution's **Best Practices** and **Clever** counts and
  how many comments it has; press `c` to open the comment thread in its place
  — rendered, not raw markdown: bold, italics, code spans and links shown as
  such, fenced code kept as a block, author in bold, rank in its kyu colour,
  score green or red, replies indented, spoilers marked —
  `<Tab>` to move between the panes, `]`/`[` or `1`–`0` to page through
  solutions. Everything comes from the solutions page itself — no extra
  requests. `:CW doctor` gains a drift check for this parser.
- Vote on solutions from the popup: `gb` for **Best Practices**, `gv` for
  **Clever** (two-key on purpose — a vote is public, and bare `b`/`v` are
  what you press by reflex in a code buffer); the same chord on a label you
  already voted retracts it. Both
  counts update from the server's reply (whatever Codewars decides about the
  other label is shown, not assumed), and a green check marks the label you
  voted. On the most-solved kata Codewars records the vote but its worker
  times out recounting and answers with an error; the plugin then re-reads
  the page instead of voting again and tells you the vote is recorded. A
  spinner runs from the keypress until the reply, so a slow vote is never
  mistaken for a key that did not register. Note that Codewars keeps one
  vote per solution per user: voting the other label moves it (verified on
  the page, not just the reply), and the site's own buttons do the same.
- The solutions popup highlights its code without setting a filetype, so your
  language servers and ftplugins no longer attach to a throwaway buffer every
  time it opens.
- Fetching solutions shows a spinner, and the parsed page is kept for ten
  minutes so reopening `:CW solutions` on the same kata is instant. Codewars
  ranks the solutions server-side before answering, which takes 1–3 s for most
  kata and up to ~7 s for the most-solved ones; that wait is the server's, not
  the plugin's. Pages are requested compressed (~440 KB → ~57 KB for such a
  kata).
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

### Fixed
- Rate limiting is handled instead of corrupting state. A 429 used to surface
  as a bare "http error 429" — or worse, as silently wrong data: the cache
  build read a refused page as "end of this rank" and wrote a truncated
  problem list stamped as fresh, an interactive search reported "No kata
  found", and a rate-limited dashboard left the whole session without an
  identity. GETs now retry with exponential backoff and jitter, honouring
  `Retry-After`; mutating requests never auto-retry a 429 (a duplicate solve
  or publish is worse than a failed one); an aborted cache build refuses to
  write a partial list, and so do the completed-kata and picker paths.
- The same honesty for every other failure: a 5xx or dead connection aborts
  the cache build as partial instead of counting as empty pages; a curl
  failure reaches the caller instead of spinning forever; scraped pages check
  the HTTP status (curl exits 0 on a 429/403, so error pages used to be
  parsed as content and reported as "session expired" or "markup changed").
- The dashboard menu centres vertically from the real window height and
  redraws on any resize, including height-only changes and resizes made from
  a neighbouring split; the pad no longer jumps as the window grows.
- Scratch buffers (solutions popup, kata test-case split) set a real filetype
  name instead of a file extension, so they are actually syntax-highlighted.
- `:checkhealth` no longer reports "unreachable" while a rate-limit retry is
  still in flight, and a late reply cannot write into an already-rendered
  report.

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
