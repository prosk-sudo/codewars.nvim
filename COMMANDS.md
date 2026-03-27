# Available Commands

Run `:CW help` inside Neovim for a quick reference.

## Training

| Command | Description |
|---|---|
| `:CW train <slug> [language]` | Open a kata by slug or URL |
| `:CW random [language]` | Open a random kata |
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

