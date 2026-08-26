# Available Commands

Run `:CW help` inside Neovim for a quick reference.

## Training

| Command | Description |
|---|---|
| `:CW train <title\|slug\|url> [language]` | Open a kata by title (as the site shows it, e.g. "Unique In Order"), slug, or URL. A trailing word that names a language is the language; quote a two-word title (`"Learn Python"`, `"Sum Squares"`) so its second word is not read as one |
| `:CW random [language]` | Open a random kata |
| `:CW focus [language] [category]` | Choose Today's Focus. `fundamentals`, `rank_up`, `practice_and_repeat`, `beta` use the server-side trainer; `random` picks locally from the cached problem list. No args opens the pickers; re-running returns the same kata until you solve or skip it |
| `:CW focus skip` | Skip the current focus kata and open the next one (uses the last `:CW focus` language + category) |
| `:CW test` | Quick test with example fixtures |
| `:CW attempt` | Full attempt with all tests (random + hidden) |
| `:CW submit` | Finalize solution (after passing attempt) |
| `:CW reset` | Reset code to template |

## Browsing

| Command | Description |
|---|---|
| `:CW list [difficulty=8,7] [order=…]` | Browse kata with filters (telescope). `difficulty=` takes kyu numbers and becomes the picker's rank filter (one rank or a set — `Ctrl-d` can widen it back to all); `order=` is one of `shuffle`, `name`, `satisfaction`, `hardest`, `easiest` — `<Tab>` completes both. Without arguments the picker keeps the filters you last chose in its menus |
| `:CW completed` | Browse completed kata (telescope) |
| `:CW solutions` | View community solutions for current kata, with Best Practices / Clever counts and comments. In the popup: `1`–`0`, `]`/`[` page through solutions, `gb` / `gv` vote Best Practices / Clever (again to retract), `c` toggles the comment pane, `<Tab>` switches pane, `q` closes |
| `:CW leaderboard [category]` | Top 500 leaderboard: `overall`, `kata` (completed), `authored`, `ranks`. No args opens the category picker; also in the menu under `l` |
| `:CW kumite` | Browse Freestyle Sparring (kumite): server-paged picker (`Ctrl-n`/`Ctrl-p` page, `Ctrl-g` go to page, `Ctrl-l` language). Menu `m`; works signed out |
| `:CW kumite open <id\|url>` | Open a kumite read-only from a `/kumite/…` link or 24-hex id |
| `:CW kumite fork` | Fork the current kumite into an editable local copy (also `Ctrl-f` in the browser) |
| `:CW kumite new [language]` | Start a fresh kumite from scratch (menu `m` → New); write code + a fixture and run it locally |
| `:CW kumite save` | Save the current kumite to codewars.com — new draft first time, in-place update after (signed-out prompts to sign in, then saves) |
| `:CW kumite publish` | Publish the saved kumite publicly (confirms first; runs the fixture and only publishes if tests pass) |
| `:CW kumite unpublish` | Hide a published kumite again (reversible) |
| `:CW kumite convert` | Convert the kumite into a new kata (confirms first; hides the kumite, reports the kata's edit URL) |
| `:CW test` | In a forked/new kumite, run your code against its fixture (signed-out prompts to sign in, then runs) |
| `:CW open` | Open kata in browser |

The kumite workspace shows its available keys at the top of the description panel; the browser lists its keys on the results border. `g?` opens the full command list.

## Authoring a Kata

A kata reaches the editor via `:CW kumite convert`, which creates the draft. These commands all act on the kata workspace in the current tab.

| Command | Description |
|---------|-------------|
| `:CW kata open <id\|url> [lang]` | Open a kata you author, from a `/kata/…` link or 24-hex id. Without a language, Codewars picks the kata's default |
| `:CW kata pane [name]` | Show one field: `answer`, `setup`, `fixture`, `example`, `description`. No name cycles to the next |
| `:CW kata meta` | Edit name, discipline, estimated rank, tags, allow-contributors. The panel stays open after each change so you can edit several fields in one go; `q` or `Esc` closes it |
| `:CW kata lang` | Switch the language you're editing, or add one — same icon dropdown as `:CW train` |
| `:CW kata version` | Pick the runtime version for the current language (e.g. Python 3.8 / 3.10 / 3.11) |
| `:CW kata validate` | Run your Complete Solution against the Test Cases (same runner as `:CW test`) |
| `:CW kata save` | Save the draft on codewars.com |
| `:CW kata publish` | Publish it publicly — confirms first, and refuses while there are unsaved edits. Codewars re-runs your tests server-side, so a failing solution/fixture pair is rejected |
| `:CW kata unpublish` | Take a published kata back to a draft (reversible) |
| `:CW kata delete` | Delete the kata for good (confirms with its name first) |

The editor's five text fields each get their own buffer; the main window shows one at a time and `g1`…`g5` switch between them, so edits in a hidden pane are never lost. The side panel is read-only and always shows the metadata, the pane list, and the keys.

Closing the tab with unsaved edits warns you — kata drafts are not stashed to the cache yet (kumite ones are).

## UI Toggles

| Command | Description |
|---|---|
| `:CW desc` | Toggle description split |
| `:CW testcases` | Toggle test cases split |
| `:CW console` | Toggle test console |
| `:CW info` | Show kata info |

## Settings

| Command | Description |
|---|---|
| `:CW lang` | Change language for current kata |
| `:CW lang default [language]` | Set/show default language (persisted across restarts) |
| `:CW template` | Report whether solution templates are on, and whether the current language has one |
| `:CW template on\|off` | Turn solution templates on or off (global, persisted). The open kata is re-wrapped or unwrapped to match; on `on`, the cursor lands at the end of your starter code. See [CONFIGS.md](CONFIGS.md#templates) |
| `:CW cookie` | Set browser cookies |
| `:CW cookie delete` | Sign out (delete stored cookies) |

## Cache

| Command | Description |
|---|---|
| `:CW cache update` | Refresh problem list cache (all languages) |
| `:CW cache clear` | Clear all session caches |

## Other

| Command | Description |
|---|---|
| `:CW stats [username]` | Show user stats |
| `:CW doctor` | Health check (dependencies, auth, cache status) |
| `:CW help` | Show all available commands |
| `:CW menu` | Open dashboard menu |
| `:CW exit` | Close codewars.nvim |

## Kata List Keybindings

| Key | Action |
|---|---|
| `Ctrl-s` | Sort: Shuffle, Name, Satisfaction, Hardest first, Easiest first |
| `Ctrl-l` | Filter by language |
| `Ctrl-d` | Filter by difficulty |
| `Ctrl-r` | Reset all filters to defaults |

## Console Keybindings

| Key | Action |
|---|---|
| `q` | Close console / toggle testcase split |

