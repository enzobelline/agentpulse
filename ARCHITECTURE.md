# AgentPulse — Technical Architecture

*Last updated: 2026-03-12*

This document covers the internal architecture decisions, data flows, and hard-won lessons from building AgentPulse. It exists to prevent re-learning the same things and to explain non-obvious design choices.

## Hook Execution Model

### How Claude Code hooks work

Claude Code fires hooks at lifecycle events (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, Stop, SessionEnd). Each hook is a shell command configured in `~/.claude/settings.json`. Claude passes a JSON payload via stdin containing fields like `session_id`, `cwd`, `hook_event_name`, `tool_name`, etc.

### The hook chain

```
Claude CLI process (connected to Terminal tab's TTY)
  └─ spawns hook command from settings.json
       └─ run_update_status.sh (bash wrapper)
            └─ python3 update_status.py (reads stdin JSON, writes session-status.json)
```

### Why hooks must NOT be backgrounded

**Rule: Never append `&` to hook commands in settings.json.**

When a hook command ends with `&`, the shell forks and the child process is detached from the process tree:

```
Claude CLI (pid=1234, tty=ttys003)
  └─ shell (forks, parent exits immediately)
       └─ backgrounded child (ppid=1 after reparenting, tty=??)
            └─ python3 (no access to original TTY)
```

This breaks:
1. **TTY capture** — `$PPID` in the wrapper points to PID 1, not Claude. `ps -p 1 -o tty=` returns `??`.
2. **PID tracking** — `os.getppid()` in Python returns 1, making the stored PID useless for process detection.

Without backgrounding, the chain stays connected:

```
Claude CLI (pid=1234, tty=ttys003)   ← $PPID in wrapper
  └─ run_update_status.sh
       └─ python3
```

Hook execution takes ~23ms. Claude does not noticeably pause.

### What data the hooks capture

| Field | Source | Written on | Purpose |
|-------|--------|-----------|---------|
| `session_id` | stdin JSON from Claude | Every event | Unique session key |
| `directory` | `stdin_data["cwd"]` or `os.getcwd()` | Every event | Grouping, display, terminal actions |
| `status` | CLI argument to update_status.py | Every event | running/waiting/done/closed |
| `pid` | `os.getppid()` | Every event | Dead PID detection (reaper) |
| `tty` | `AGENTPULSE_TTY` env var (from wrapper) | Every event | Session attach (Terminal window focus) |
| `summary` | Extracted from UserPromptSubmit prompt | On prompt submit | Display label |
| `activity` | Extracted from PostToolUse tool_name/input | On tool use | Live activity label |
| `symbol` | Assigned from pool on first event | Once per session | Visual identity in menubar |

### TTY capture: the full story

**Goal:** When user clicks a session row, find and focus the Terminal.app window where that Claude session is running.

**Solution:** Match by TTY device path.

**Capture (hook time):**
1. `run_update_status.sh` runs `ps -p $PPID -o tty=` — returns e.g. `ttys003`
2. Exports as `AGENTPULSE_TTY=ttys003`
3. `update_status.py` reads env var, stores `session["tty"] = "/dev/ttys003"`

**Match (click time):**
1. Swift reads `session.tty` from JSON
2. AppleScript iterates `windows` → `tabs` of Terminal.app
3. Compares `tty of tab` to stored value
4. On match: selects tab, sets window index to 1 (brings to front), activates Terminal
5. No match: falls back to opening new terminal at session directory

**Why not other approaches:**

| Approach | Why it failed |
|----------|--------------|
| `os.getppid()` → PID | Returns 1 when hooks backgrounded via LaunchAgent |
| Process tree walk | Backgrounding (`&`) breaks the tree — parent exits, child reparented to PID 1 |
| `tty` command in wrapper | Hook's stdin is piped JSON, not a terminal. `tty` returns "not a tty" |
| `lsof -d cwd` on Claude PID | macOS reports home dir for all Claude processes regardless of actual working directory |
| Match `--resume <uuid>` args | Claude's resume UUID doesn't match the `session_id` from hooks — different ID spaces |
| Window title matching | Terminal window titles don't reliably contain the project directory name |
| `$PPID` with `&` | Backgrounded process's parent exits immediately, `$PPID` becomes 1 |
| `$PPID` without `&` | **This works.** Parent is Claude CLI, which has the TTY. |

**Edge cases:**
- Old sessions without `tty` field: falls back to opening new terminal
- Session's Terminal window closed: no matching TTY found, opens new terminal
- Multiple tabs on same window: finds and selects the correct tab

## Worktree Architecture

### Sibling layout (not nested)

```
/home/dev/
  myproject/              ← original repo
  myproject-falcon/       ← worktree (sibling, auto-named)
  myproject-otter/        ← another worktree
```

Previous design nested worktrees inside `.worktrees/` inside the repo, which required `.gitignore` management and was harder to discover.

### Auto-naming

~200 animal words in `worktreeWords` (in AgentPulseLib for testability). `pickUnusedWord()` checks existing directory names matching `<repo>-<word>` pattern and returns a random unused word. Returns nil when all exhausted.

### Branching from worktrees

`git worktree add` works from inside another worktree (git shares the object database). `git rev-parse --show-toplevel` from inside a worktree returns that worktree's root, which is used to determine the parent directory for sibling placement.

### Lineage detection

`worktreeLineage(directoryName:)` splits on the last hyphen and checks if the suffix is a known word. Handles hyphenated repo names: `my-cool-project-falcon` → `("falcon", "my-cool-project")`.

## Session Data Architecture

### Directory field

`session["directory"]` is overwritten on every hook event with the current `cwd` from Claude's stdin JSON. It's "latest cwd" not "launch directory." In practice these are the same because Claude doesn't change cwd mid-session, but the code doesn't assume that.

The directory drives:
- Group headers in the dropdown menu (basename)
- Fallback summary label when prompt is a placeholder
- Worktree lineage display (`word → repo`)
- "Open in Terminal" path
- "Create New Worktree" repo root detection

### PID field

`session["pid"]` is `os.getppid()` — the parent of the Python hook script. Without backgrounding, this is the Claude CLI process. Used only for dead PID detection (session reaper), not for TTY lookup (which uses the `tty` field instead).

### TTY field

`session["tty"]` is the Terminal tab's TTY device path (e.g. `/dev/ttys003`). Captured by the shell wrapper via `ps -p $PPID -o tty=`. Used exclusively for session-attach (finding and focusing the Terminal window on click).

## AppleScript Usage

AgentPulse uses AppleScript (`NSAppleScript`) in three places:

1. **Attach to session** — iterates Terminal.app windows/tabs, matches TTY, brings window to front
2. **Open in Terminal** — `do script "cd /path"` opens a new Terminal window
3. **Worktree launch** — `do script "cd /path && claude"` opens Terminal and starts Claude

These are distinct from **terminal-notifier** which handles desktop notifications (banners). terminal-notifier and AppleScript serve completely different purposes:
- terminal-notifier → push notification banners to Notification Center
- AppleScript → control Terminal.app windows programmatically

## Testing Architecture

### Unit tests (pure logic, no I/O)

In `AgentPulseLib` target — testable without AppKit:
- `pickUnusedWord` — word selection with various taken/available states
- `worktreeLineage` — directory name pattern matching
- Sort order, display labels, session reaper

### Integration tests (real git repos)

In `WorktreeHelpersTests` — create actual git repos in temp directories:
- Each test creates a unique temp dir: `FileManager.default.temporaryDirectory` + UUID
- All git operations use `Process` with `/usr/bin/git`
- Cleanup via `defer { try? FileManager.default.removeItem(at: tmp) }`
- Tests verify: worktree creation, porcelain parsing, dirty-commit-branch flow, worktree-from-worktree

No test artifacts persist on disk. The OS temp directory provides additional cleanup as a safety net.

## Session Lifecycle

### Hook event → status mapping

```
SessionStart      → "running"     (session appears in menubar)
UserPromptSubmit  → "running"     (captures user prompt as summary)
PreToolUse        → "running"     (clears stale "waiting" before tool execution)
PostToolUse       → "running"     (captures tool activity)
PostToolUseFailure→ "running"     (clears "waiting" after tool failure)
PermissionRequest → "waiting"     (notification sent)
Stop              → "done"        (notification sent, session still alive in terminal)
  ↕ user types another prompt → back to "running"
SessionEnd       → "closed"      (recorded to history, then removed from active sessions)
```

**Critical distinction:** "done" = Claude finished its current turn, waiting for user input. "Closed" = session truly exited (`/exit`, Ctrl+C, terminal closed). History only records on "closed", not "done".

### Session history and resume

When a session transitions to "closed", the Swift app:
1. Checks if the session had a real user prompt (not a placeholder like "Session started")
2. Records the session to `~/.claude/session-history.json` with `sessionId`, `lastMessage`, directory, etc.
3. Removes the session from active sessions and releases its symbol

**Important:** The "closed" handler runs unconditionally — it is NOT gated behind the notification/sound settings guard. This ensures history records even when notifications and sound are both disabled.

Clicking a history entry runs `cd <directory> && claude --resume <sessionId>` in a new Terminal window. The `sessionId` from hooks IS the same UUID used by `claude --resume`.

### History management

Each history entry in the dropdown has a submenu with:
- **Resume** — opens Terminal with `cd <dir> && claude --resume <id>`
- **Delete** — removes just that entry from history

A **Clear History** button at the bottom of the history submenu prompts "Are you sure?" before wiping all entries.

NSMenu items with submenus cannot fire their own action on click — the submenu opens on hover instead. So history entries are non-actionable parents; Resume and Delete are in the submenu.

### Reaper vs SessionEnd race condition

**Problem:** The dead PID reaper runs every 1 second. When Claude exits (`/exit`), the Stop hook fires (status → "done"), then the process dies. The reaper may detect the dead PID and remove the "done" session before the SessionEnd hook fires. When SessionEnd arrives with status "closed", `update_status.py` looks up the session — it's gone, so nothing happens. History never records.

```
Stop hook → status "done" → PID dies → reaper removes session → SessionEnd hook → session not found → no history
```

**Fix (Python side):** When "closed" arrives and the session doesn't exist, `update_status.py` creates a minimal entry with backfilled fields (`directory`, `name`, `symbol`, `started_at`) so the Swift app can still pick it up for history.

**Fix (Swift side):** The "closed" transition handler was inside `postNotificationIfNeeded`, gated behind `guard wantsNotification || wantsSound`. Moved the "closed" check before this guard so history always records.

### Ghost session filtering

Ghost sessions are sessions that were started but never received a real user prompt. These come from briefly launching `claude` and immediately exiting — NOT from subagents (Task tool subagents run inside the same CLI process and don't fire separate hooks).

Detection: check if the session summary is a placeholder value ("Session started", "Process ended", "Processing...", "Needs permission", "Finished"). If so, skip recording to history.

### Stop hook fields

The Stop hook provides: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `stop_hook_active`, `last_assistant_message`. It does **NOT** provide `total_cost_usd`, `total_input_tokens`, or `total_output_tokens`.

## Session Cleanup

### TTY-based deduplication

When `claude --resume <id>` is used, Claude generates a **new** `session_id` in hook payloads — it does not reuse the original. This means the old session lingers in `session-status.json` while a new one appears.

**Fix:** In `update_status.py`, before creating/updating a session, scan all existing sessions. If another session owns the same TTY, remove it and release its symbol. This works because only one Claude process can run in a terminal tab at a time.

```python
if tty_path and status != "closed":
    for key in list(sessions.keys()):
        if key != session_key and sessions[key].get("tty") == tty_path:
            release_symbol(data, key)
            sessions.pop(key)
```

### Dead PID reaper (enhanced)

The Swift app's reaper runs every 1 second and checks `kill(pid, 0)`:

| Session Status | PID Alive | Action |
|---|---|---|
| running/waiting | Dead | Mark as "done" (summary: "Process ended") |
| done | Dead | **Remove entirely** + release symbol |
| done | Alive | Keep (process still running or PID recycled) |
| any | No PID | Skip |

Previously, "done" sessions with dead PIDs were kept indefinitely, requiring manual dismiss or TTL expiry. Now they auto-vanish.

**Caveat:** `os.getppid()` captures the Claude CLI's PID, but after Claude exits, the parent shell process may keep the same PID alive. In practice, PID recycling and shell exit cause the reaper to eventually clean up, but some sessions may persist slightly longer than expected.

### Worktree session grouping

Sessions in worktree directories (e.g. `/home/dev/myproject-falcon`) are grouped with their parent repo (`/home/dev/myproject`) in the dropdown menu via `groupKey(forDirectory:)`. This function uses `worktreeLineage()` to detect the `<repo>-<word>` pattern and maps back to the parent path.

The group header shows the parent repo's basename. Worktree sessions display both their unique symbol and lineage: `⠋ ♪ falcon → myproject · Fixing auth - running`.

## Common Pitfalls

1. **Don't background hooks** — `&` at the end of hook commands breaks TTY capture and PID tracking
2. **Don't use `tty` command in hooks** — hook stdin is piped JSON, not a terminal device
3. **Don't trust `os.getppid()` from LaunchAgent hooks** — returns 1 (launchd) when backgrounded
4. **Don't match Terminal windows by title** — titles are unreliable and user-configurable
5. **Don't use `lsof -d cwd`** — macOS often reports home directory for all processes regardless of actual cwd
6. **Hook `session_id` IS the `--resume` UUID** — they're the same ID space. `claude --resume <session_id>` works. However, `claude --resume` creates a NEW `session_id` for hook payloads, so TTY dedup is needed to clean up the old entry.
7. **`ps -o tty=` returns `ttys003` not `/dev/ttys003`** — prepend `/dev/` not `/dev/tty`
8. **`Result<Bool, String>` doesn't compile in Swift** — `String` doesn't conform to `Error`, use a tuple instead
9. **Session reaper overwrites simulated test sessions** — `os.getppid()` in hook scripts returns the parent PID. When simulating hooks from the command line, the parent exits immediately, so the reaper marks the session as "done" within 1 second. Real Claude CLI sessions stay alive so this isn't a problem in practice.
10. **Claude Code terminal title is not accessible from hooks** — The smart title shown in Terminal.app (e.g. "Terminal Header Differences") is generated internally by the Claude CLI and written via ANSI escape sequences (`\033]0;Title\007`). It is not stored in the transcript JSONL, not passed via hook stdin, and not persisted anywhere on disk. The only summary we can build is from the raw `prompt` field in `UserPromptSubmit`.
11. **NSMenuDelegate `willHighlight` enables hover-to-preview** — `menu(_:willHighlight:)` fires when a menu item is highlighted (hovered), enabling live sound preview in submenus without clicking.
12. **Don't use `lockFocus`/`unlockFocus` for SF Symbol tinting** — SF Symbols are vector-based; the old bitmap `lockFocus` approach produces empty/invisible images. Use `NSImage.SymbolConfiguration(hierarchicalColor:)` instead.
13. **`claude --resume` generates a new `session_id` in hooks** — even though the resume UUID and hook `session_id` are the same ID space, resuming creates a NEW session_id for hook events. TTY dedup handles this by cleaning up old sessions on the same terminal tab.
14. **"Done" sessions with dead PIDs should be removed, not kept** — previously the reaper only transitioned running/waiting → done. Dead "done" sessions piled up indefinitely. Now they're auto-removed.
15. **Reaper can remove sessions before SessionEnd fires** — Stop → PID dies → reaper removes "done" session → SessionEnd finds nothing → history skipped. Fix: `update_status.py` backfills a minimal "closed" entry when the session is already gone.
16. **"Closed" handler must not be gated behind notification settings** — history recording was inside `postNotificationIfNeeded`, guarded by `guard wantsNotification || wantsSound`. If both disabled, history never recorded. Moved "closed" handling before the guard.
17. **NSMenuItem with submenu can't fire its own action** — clicking opens the submenu, not the action. History entries must use submenu items for Resume/Delete rather than click-to-resume + hover-for-submenu.

## Notification Architecture

### Four-state notification model

Two independent toggles (`notificationsEnabled` + `soundEnabled`) produce four behaviors:

| Notifications | Sound | Result |
|---|---|---|
| On | On | Banner + sound (via terminal-notifier or osascript) |
| On | Off | Silent banner (notification with no sound) |
| Off | On | Sound only (`NSSound.play()`, no banner) |
| Off | Off | Nothing |

### Per-event sounds

Each event type has its own configurable sound stored in settings:

| Event | Setting | Default | Purpose |
|---|---|---|---|
| Waiting (needs permission) | `waiting_sound` | Purr | Gentle attention nudge |
| Done (finished) | `done_sound` | Glass | Satisfying completion chime |

Sounds are played via:
- **With banner**: terminal-notifier `-sound` flag or osascript `sound name` parameter
- **Without banner**: `NSSound(named:)?.play()` directly

### Sound picker UI

Three-level nested menu: `Sound: On ▸ Turn Off | Waiting: Purr ▸ [sounds] | Done: Glass ▸ [sounds]`

`SoundPickerMenu` is an `NSMenu` subclass that implements `NSMenuDelegate`. The `willHighlight` delegate method plays the sound when the user hovers over an option, providing live preview before selection.

## Prompt Summary Architecture

### Preamble stripping

`_strip_preamble()` in `update_status.py` removes conversational prefixes from user prompts to extract the meaningful action. The function:

1. Maintains a static list of ~70 prefix patterns, ordered longest-first within categories
2. Loops until no more prefixes match (handles chained preamble like "Yeah, let's go ahead and")
3. Is case-insensitive but preserves the original casing of the remaining text
4. After stripping, the first letter is auto-capitalized

**Important:** Only one prefix is stripped per loop iteration (`break` after match), but the outer loop continues. This prevents accidentally stripping content that happens to start with a prefix word after the first strip.

### Why not use Claude's terminal title

The terminal title (e.g. "Terminal Header Differences") would be ideal as a session summary, but it's inaccessible:
- Not in hook stdin JSON (`prompt`, `session_id`, `cwd`, `hook_event_name` only)
- Not in transcript JSONL (messages, progress, system events — no title field)
- Not in any metadata file on disk
- Generated internally by Claude CLI, written directly to terminal via ANSI OSC escape sequences
- The `transcript_path` field is available but contains the full conversation JSONL, not a summary

## Testability Pattern

### Extracting pure functions for testability

AppKit code (StatusBarController, SessionStore) can't be easily unit tested. The pattern used throughout:

1. Extract pure logic into `AgentPulseLib` (no AppKit dependency)
2. AppKit code calls the pure function
3. Tests import `AgentPulseLib` only

Examples:
- `expiredSessionKeys()` — extracted from `SessionStore.clearExpiredSessions()`
- `autoClearLabel()` — extracted from `StatusBarController.autoClearLabel()`
- `reapStaleSessions()` — extracted from `SessionStore.reapStaleSessions()`
- `resolveAttachAction()` — decides between TTY-based window focus vs new terminal
- `isValidTTY()` — validates `/dev/ttysNNN` format
- `detectStatusTransitions()` — compares old/new session snapshots for notification triggers
- `pickUnusedWord()`, `worktreeLineage()`, `groupKey()` — pure from the start

## Cross-Space Window Attach

### Problem

Clicking a session row sometimes brought the Terminal window to the current Space instead of switching to the window's Space. Inconsistent behavior.

### Root cause

AppleScript's `activate` command is less reliable for cross-Space switching than Cocoa's native `NSRunningApplication.activate()`. The old code did everything in one AppleScript block.

### Fix

Split into two steps:
1. **AppleScript** — finds matching TTY tab, selects it, sets `index of w to 1` (frontmost within Terminal)
2. **Swift `NSRunningApplication.activate()`** — handles activation through Cocoa's window server, which respects the "switch to Space with open windows" Mission Control setting

### Requirement

macOS setting must be ON: System Settings -> Desktop & Dock -> Mission Control -> "When switching to an application, switch to a Space with open windows"

## Stuck "Waiting" Status Fix

### Problem

Menubar showed "waiting" when Claude was actually running normally.

### Root cause

Two missing hooks in the event chain:

```
PermissionRequest → "waiting"
[user approves]
[tool executes — status STUCK on "waiting"]
PostToolUse → "running"       ← only fires on SUCCESS
PostToolUseFailure → ???      ← NO HOOK — status stays "waiting"
```

### Fix

Added two hooks:
- `PreToolUse → running` — fires before every tool, clears stale "waiting"
- `PostToolUseFailure → running` — fires on tool failure, clears "waiting"

Shadow file writes skip these high-frequency events (no history data to record).

## Menu Animation While Open

### Problem

Spinner animation froze when the dropdown menu was open.

### Root cause

The 1-second store timer called `refresh()` which sometimes triggered `buildMenu()`. This created a new `NSMenu` and set `statusItem.menu = newMenu`, but the *old* menu was still being displayed. `sessionMenuItems` then pointed to the invisible new menu, so title updates had no effect.

### Fix

1. Track `menuIsOpen` via `NSMenuDelegate` (`menuWillOpen` / `menuDidClose`)
2. While menu is open, defer `buildMenu()` — only update titles in-place
3. Dedicated animation timer drives spinner frame advancement during menu tracking
4. Deferred rebuild applies in `menuDidClose`

## Single-Instance Guard

### Problem

`pkill` + manual restart created duplicates because the LaunchAgent (`KeepAlive: true`) auto-restarted immediately.

### Fix

On launch, check for existing AgentPulse processes via `NSWorkspace.shared.runningApplications`. If another instance is found, quit immediately. This prevents duplicates regardless of how the app is launched.

## CI / Release Pipeline

### GitHub Actions workflows

| Workflow | Trigger | What it does |
|---|---|---|
| **CI** (`ci.yml`) | Push/PR to main | Build, test, install smoke test |
| **Release** (`release.yml`) | Push `v*` tag | Test, build universal binary, create GitHub Release |

### CI details

Two jobs run in sequence:

1. **build-and-test** — `swift build -c release` + `swift test` (145 tests, 7 suites)
2. **install-smoke-test** — runs `./install.sh` end-to-end on a clean macOS runner, then verifies:
   - Binary exists at `.build/release/AgentPulse`
   - LaunchAgent plist was created
   - Hooks were written to `~/.claude/settings.json`
   - AgentPulse process is running

Both jobs use `.build/` caching keyed on `Package.swift`, `Package.resolved`, and source file hashes. Cache hits skip the ~30s dependency resolution and compilation.

### Release process

1. Merge changes to main (CI must pass)
2. `git tag -a v0.1.x -m "release notes" && git push origin v0.1.x`
3. Release workflow builds a universal binary (arm64 + x86_64), assembles `AgentPulse.app`, zips it with `ditto`, and creates a GitHub Release with auto-generated notes

Artifacts attached to each release:
- `AgentPulse-v0.1.x.zip` — the `.app` bundle (recommended path for users)
- `agentpulse-v0.1.x-macos-universal.tar.gz` — raw binary + install scripts (for contributors who prefer source-style install)
