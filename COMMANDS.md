# Available Commands

Run `:CW help` inside Neovim for a quick reference.

## Training

| Command | Description |
|---|---|
| `:CW train <slug> [language]` | Open a kata by slug or URL |
| `:CW random [language]` | Open a random kata |
| `:CW focus [language] [category]` | Choose Today's Focus. `fundamentals`, `rank_up`, `practice_and_repeat`, `beta` use the server-side trainer; `random` picks locally from the cached problem list. No args opens the pickers; re-run for the next kata |
| `:CW test` | Quick test with example fixtures |
| `:CW attempt` | Full attempt with all tests (random + hidden) |
| `:CW submit` | Finalize solution (after passing attempt) |
| `:CW reset` | Reset code to template |

## Browsing

| Command | Description |
|---|---|
| `:CW list` | Browse kata with filters (telescope) |
| `:CW completed` | Browse completed kata (telescope) |
| `:CW solutions` | View community solutions for current kata |
| `:CW leaderboard [category]` | Top 500 leaderboard: `overall`, `kata` (completed), `authored`, `ranks`. No args opens the category picker; also in the menu under `l` |
| `:CW kumite` | Browse Freestyle Sparring (kumite): server-paged picker (`Ctrl-n`/`Ctrl-p` page, `Ctrl-g` go to page, `Ctrl-l` language). Menu `m`; works signed out |
| `:CW kumite open <id\|url>` | Open a kumite read-only from a `/kumite/…` link or 24-hex id |
| `:CW kumite fork` | Fork the current kumite into an editable local copy (also `Ctrl-f` in the browser) |
| `:CW kumite new [language]` | Start a fresh kumite from scratch (menu `m` → New); write code + a fixture and run it locally |
| `:CW test` | In a forked/new kumite, run your code against its fixture (signed-out prompts to sign in, then runs) |

The kumite workspace shows its available keys at the top of the description panel; the browser lists its keys on the results border. `g?` opens the full command list.
| `:CW open` | Open kata in browser |

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
| `Ctrl-s` | Sort: Shuffle, Name, Satisfaction |
| `Ctrl-l` | Filter by language |
| `Ctrl-d` | Filter by difficulty |
| `Ctrl-r` | Reset all filters to defaults |

## Console Keybindings

| Key | Action |
|---|---|
| `q` | Close console / toggle testcase split |

