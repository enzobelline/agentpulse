# AgentPulse — Feature & Bug Tracker

## v2.4 — Session History Resume, Lifecycle Fixes, Cleanup (2026-02-24)

### Feature 6: Global Hotkey — Removed

Removed `Cmd+Shift+A` global hotkey (HotkeyManager.swift deleted). Requires macOS Accessibility permission which is impractical without a proper .app bundle — permission revoked on every rebuild.

### Feature 7: Cost/Token Tracking — Removed

Removed token/cost display from session submenu. The Stop hook does NOT provide `total_cost_usd`, `total_input_tokens`, or `total_output_tokens` — these fields don't exist in the payload. Removed `extract_cost_tokens()` from update_status.py and `tokensIn/tokensOut/costUsd` from Session model.

### Feature 8 Tweak: Session History — Resume + Better Summaries + Management

History entries now store the session ID and Claude's last response, enabling one-click resume:

- [x] Click history entry → opens Terminal with `cd <dir> && claude --resume <session_id>`
- [x] `sessionId` stored in HistoryEntry for resume
- [x] `lastMessage` captured from Stop hook's `last_assistant_message` field (truncated to 200 chars)
- [x] Tooltip shows last message or prompt summary on hover (50 chars)
- [x] Ghost session filter: only sessions with real user prompts are recorded (skips "Session started", "Process ended", etc.)
- [x] Each history entry has submenu with "Resume" and "Delete" options
- [x] "Clear History" button at bottom of history submenu with "Are you sure?" confirmation dialog
- [x] `SessionHistory.removeEntry(at:)` and `clearAll()` methods

### Fix: Session Lifecycle — "closed" vs "done"

"Done" means Claude finished its current turn (session still alive). "Closed" means the session truly exited (`/exit`, Ctrl+C). Previously, history recorded on every "done" transition, creating duplicates. Now:

- [x] `update_status.py` sets status to "closed" on SessionEnd (instead of deleting immediately)
- [x] Swift app detects "closed" transition → records to history → removes session
- [x] History only records truly exited sessions, not mid-conversation pauses
- [x] `removeSessions()` now releases symbols back to pool

### Fix: Reaper vs SessionEnd Race Condition

The dead PID reaper could remove "done" sessions before the SessionEnd hook fired, causing the "closed" handler to find no session and silently skip history recording. Two fixes:

- [x] `update_status.py` "closed" handler now creates a minimal session entry if the session was already reaped (backfills directory, name, symbol)
- [x] Swift "closed" handler moved outside the `guard wantsNotification || wantsSound` gate — history records regardless of notification settings

### Fix: Permissions Guidance

- [x] First-run popup explains Automation (Terminal) and Notification permissions
- [x] "Don't show this again" checkbox — popup shows every launch until suppressed
- [x] `install.sh` prints permission instructions after install
- [x] `install.sh` fixed: removed `&` from hook commands (long-standing issue)

### Subagent Investigation

Task tool subagents do NOT fire separate hooks — they run inside the same Claude CLI process. Ghost sessions in history were from briefly-launched Claude instances that never received a user prompt, not from subagents. Filtered by checking summary against placeholder values.

## v2.3 — Worktree Grouping, TTY Dedup, Dead Session Cleanup (2026-02-24)

### Feature 5 Tweak: Worktree Session Grouping

Worktree sessions now group with their parent repo in the dropdown menu. A session in `agentpulse_swift-falcon` appears under the `agentpulse_swift` group header instead of its own separate group.

- [x] `groupKey(forDirectory:)` in WorktreeHelpers.swift — maps worktree paths to parent repo path
- [x] `buildMenu()` uses `groupKey` for grouping instead of raw directory
- [x] Worktree sessions display both symbol and lineage: `⠋ ♪ falcon → agentpulse · ...`
- [x] 7 new tests for `groupKey` (plain dir, worktree, hyphenated repo, unknown suffix, home dir, parent match, multi-worktree match)

### Fix: SF Symbol Rendering

Replaced deprecated `lockFocus()`/`unlockFocus()` bitmap tinting with modern `hierarchicalColor` API for SF Symbol status icons. The old approach produced empty/invisible images with vector-based SF Symbols.

- [x] `statusImage(for:)` now uses `NSImage.SymbolConfiguration(hierarchicalColor:)`
- [x] Removed dead `NSImage.tinted(with:)` extension

### Fix: TTY-Based Session Deduplication

When resuming a Claude session (`claude --resume <id>`), Claude generates a new `session_id` even though it's the same terminal tab. The old session lingered as stale. Now `update_status.py` deduplicates by TTY: if a new session starts on a TTY already owned by another session, the old one is removed.

- [x] TTY dedup in `update_status.py` — scans existing sessions for matching TTY before creating new entry
- [x] Releases symbol of displaced session back to pool

### Fix: Dead Session Auto-Removal

"Done" sessions with dead PIDs now get removed entirely by the reaper (every 1s), instead of just lingering until manual dismiss or TTL expiry. Sessions with live PIDs are kept.

- [x] `reapStaleSessions()` now removes "done" sessions with dead PIDs (previously only marked running/waiting → done)
- [x] `SessionStore.reapStaleSessions()` releases symbols for removed sessions
- [x] Updated 2 existing tests, added 1 new test for done+live PID retention
- [x] 81 tests passing across 4 suites

## v2.2 — Notification & Sound Overhaul + Smart Summaries (2026-02-24)

### Feature 2 Tweak: Auto-Clear TTL Options

Expanded the auto-clear TTL options from `[0, 2, 5, 15, 30]` to `[0, 5, 15, 30, 60, 180, 1440]` with human-readable labels (1h, 3h, 1d). Extracted `autoClearLabel()` as a public function in AgentPulseLib for testability. Also extracted `expiredSessionKeys()` as a pure function for TTL expiry logic testing.

- [x] New options: Off / 5m / 15m / 30m / 1h / 3h / 1d
- [x] `autoClearLabel()` in DisplayLabels.swift — tested with 4 parameterized tests
- [x] `expiredSessionKeys()` in SessionReaper.swift — tested with 6 boundary/behavior tests
- [x] Boundary precision verified: 1 second before TTL → not expired, exact TTL → expired

### Feature 3 Tweak: Notification & Sound Independence + Sound Picker

Split the old `soundEnabled` toggle (which gated ALL notifications) into two independent controls:

| Notifications | Sound | Result |
|---|---|---|
| On | On | Banner + sound |
| On | Off | Silent banner |
| Off | On | Sound only, no banner |
| Off | Off | Nothing |

Added per-event sound customization with live preview on hover:

- [x] `notificationsEnabled` setting (default `true`, backward-compatible decoding)
- [x] `waitingSound` and `doneSound` settings (default "Purr" and "Glass")
- [x] Nested menu structure: Sound: On/Off ▸ Turn On/Off, Waiting: Purr ▸ [sounds...], Done: Glass ▸ [sounds...]
- [x] `SoundPickerMenu` class — NSMenuDelegate `willHighlight` plays sound on hover for live preview
- [x] Three levels of submenu nesting (dropdown → Sound → Waiting/Done → sound options)
- [x] `playSoundOnly()` on NotificationManager — plays NSSound without banner
- [x] 7 available sounds: Glass, Purr, Tink, Pop, Bottle, Ping, Sosumi
- [x] 4 new tests for `notificationsEnabled` decoding

### Feature 4 Tweak: Smart Prompt Summaries (Preamble Stripping)

Prompt summaries in the dropdown now strip conversational preamble to show the meaningful action:

**Before:** "Yeah sure, can you please go ahead and fix the bug"
**After:** "Fix the bug"

- [x] `_strip_preamble()` in update_status.py — ~70 prefix patterns covering polite requests, acknowledgements, affirmations/negations, transitions, filler starters
- [x] Multi-layer stripping (loops until no more matches) — handles chained preamble like "Yeah, let's go ahead and"
- [x] Auto-capitalizes first letter after stripping
- [x] Truncation limit bumped from 30 → 40 chars (more room after stripping)
- [x] Word boundary threshold adjusted accordingly (20 → half of max)

#### Prefix categories covered:
- Polite requests: "can you please", "would you mind", "could you also"
- Acknowledgements: "sounds good", "great", "perfect", "awesome", "nice", "cool"
- Affirmations: "yeah", "yes", "yep", "sure", "ok", "alright"
- Negations: "no", "nah", "nope"
- Transitions: "now", "next", "then", "also", "so"
- Greetings: "hey", "hi"
- Hedges: "I think", "I guess", "just", "maybe", "basically", "actually"
- Multi-word: "let's go ahead and", "I was wondering if you could", "do you think we could"

#### Files Modified
- `Sources/AgentPulseLib/Models.swift` — Added `notificationsEnabled`, `waitingSound`, `doneSound`, `availableSounds` (static) to Settings
- `Sources/AgentPulseLib/DisplayLabels.swift` — Added `autoClearLabel()`, bumped default maxLength to 40
- `Sources/AgentPulseLib/SessionReaper.swift` — Added `expiredSessionKeys()` pure function
- `Sources/AgentPulse/Constants.swift` — Updated autoClearOptions to include 60, 180, 1440
- `Sources/AgentPulse/NotificationManager.swift` — Added `playSoundOnly()`, `soundName` parameter throughout
- `Sources/AgentPulse/SessionStore.swift` — Independent notification/sound gating, per-event sound names, uses `expiredSessionKeys()`
- `Sources/AgentPulse/StatusBarController.swift` — Nested Sound submenu with SoundPickerMenu, Notifications toggle, uses `AgentPulseLib.autoClearLabel()`
- `update_status.py` — `_strip_preamble()` with multi-layer stripping, 40-char truncation
- `Tests/AgentPulseTests/DisplayLabelsTests.swift` — Updated for 40-char default, added autoClearLabel tests
- `Tests/AgentPulseTests/SessionLifecycleTests.swift` — Added TTL expiry tests, notification settings tests

#### Test Results
- 73 tests passing across 4 suites (59 → 73, +14 new tests)

---

## v2.1 — Click to Branch + Attach to Session (2026-02-23)

### Feature 1 Rewrite: Attach to Session + One-Click Worktree

Replaced "Click to Open Terminal" with two new features:

1. **Attach to Session** — clicking a session row finds the Terminal window where Claude is running and brings it to front. No more hunting through terminal windows.
2. **Create New Worktree** — moved to session submenu. Creates a sibling git worktree with auto-naming and launches Claude in it.

#### What Changed
- [x] **Session row click** now attaches to the Terminal window via TTY matching (was: open Terminal cd'd to dir)
- [x] **"Create New Worktree"** in session submenu — creates sibling worktree + launches Claude
- [x] **Sibling worktree layout** — `myproject-falcon/` next to `myproject/` (was: nested `.worktrees/` inside repo)
- [x] **Auto-naming** — ~200 animal words, randomly picked, checked against existing worktrees
- [x] **Dirty repo dialog** — 3 options: "Branch Anyway" / "Commit & Branch" / "Cancel"
- [x] **Worktree lineage display** — sessions in worktree dirs show `falcon → myproject` instead of symbol
- [x] **Removed Feature 11** "New Branch Session…" menu item (superseded by submenu action)
- [x] **"Open in Terminal"** still available in session submenu as fallback
- [x] **Notification/history clicks** unchanged (still open terminal — correct for those contexts)
- [x] **TTY capture** — hooks now store the Terminal tab's TTY device path in session data
- [x] **Hooks run synchronously** — removed `&` backgrounding from all 6 hooks (23ms execution, imperceptible)

#### How Attach to Session Works

The session-attach feature required solving a non-obvious problem: how does the Swift menubar app know which Terminal.app window/tab belongs to a given Claude session?

**Solution: TTY device matching**

Each Terminal.app tab is connected to a TTY device (e.g. `/dev/ttys003`). The flow:

1. **Hook time** (`run_update_status.sh`): Captures the TTY of the parent process (`$PPID`) via `ps -p $PPID -o tty=`. Since hooks run synchronously (no `&`), `$PPID` is the Claude CLI process, which is connected to the Terminal tab's TTY. The TTY is passed to Python via `AGENTPULSE_TTY` env var.

2. **Python** (`update_status.py`): Reads `AGENTPULSE_TTY`, prepends `/dev/`, stores as `session["tty"]` in the JSON (e.g. `/dev/ttys003`).

3. **Swift** (`StatusBarController.swift`): On click, reads `session.tty`, uses AppleScript to iterate Terminal.app windows/tabs, matches `tty of tab` to the stored value, selects the tab and brings the window to front.

4. **Fallback**: If no TTY is stored (old session, remote session), opens a new Terminal cd'd to the session's directory.

#### Bugs Encountered and Fixed During Development

**Bug: PID always 1** — `os.getppid()` in the hook Python script returned `1` (launchd) instead of Claude's PID. Root cause: hooks ran through a LaunchAgent, and the hook's parent was the LaunchAgent runner, not Claude.

**Bug: Process tree walk failed** — Attempted to walk up the process tree via `ps -p <pid> -o ppid=` to find a process with a TTY. Failed because hooks were backgrounded with `&`, which forks the shell and detaches from the process tree. The backgrounded child's parent quickly exits, reparenting to PID 1.

**Bug: `tty` command returned "not a tty"** — Attempted to use the `tty` command in the shell wrapper. Failed because hooks receive stdin as piped JSON from Claude Code, not from the terminal. The script's stdin is not a TTY even though the parent process is connected to one.

**Bug: TTY path double-prefix** — `ps -o tty=` returns `ttys003` (already includes `tty` prefix). Code prepended `/dev/tty`, producing `/dev/ttyttys003`. Fixed to prepend `/dev/` only.

**Fix: Remove `&` + use `$PPID`** — The hooks only take 23ms. Removing `&` keeps the process tree intact. `$PPID` in the shell wrapper is now the Claude CLI process, which has a real TTY. The wrapper captures it via `ps -p $PPID -o tty=` and exports it as `AGENTPULSE_TTY`.

#### Files Added
- `Sources/AgentPulseLib/WorktreeHelpers.swift` — `worktreeWords`, `pickUnusedWord()`, `worktreeLineage()` (pure, testable)
- `Tests/AgentPulseTests/WorktreeHelpersTests.swift` — 15 tests (unit + integration with temp git repos)

#### Files Modified
- `Sources/AgentPulse/WorktreeManager.swift` — Full rewrite: `branchFromSession(directory:)` entry point, dirty dialog, auto word picking, sibling worktree creation, error handling for every git command
- `Sources/AgentPulse/StatusBarController.swift` — Row click → `attachToSession` (TTY match), submenu gains "Create New Worktree", removed "New Branch Session…" menu block, added lineage display in `sessionTitle()`
- `Sources/AgentPulseLib/Models.swift` — Added `tty` field to Session
- `update_status.py` — TTY capture from `AGENTPULSE_TTY` env var, stored as `session["tty"]`
- `run_update_status.sh` — Captures parent process TTY via `ps -p $PPID -o tty=`, exports as `AGENTPULSE_TTY`
- `~/.claude/settings.json` — Removed `&` (backgrounding) from all 6 hook commands

#### Test Results
- 59 tests passing (44 existing + 15 new)
- Integration tests create real git repos in temp directories, verify worktree creation, porcelain parsing, dirty-then-commit flow, and worktree-from-worktree — all cleaned up via `defer`

---

## v2.0 — Top 10 Feature Release (Feb 2026)

### New Features

#### 1. Click to Open Terminal (superseded by v2.1 Click to Branch)
- [x] ~~Session rows clickable — single click opens Terminal.app `cd`'d to session directory~~ → Now creates worktree + launches Claude
- [x] "Open in Terminal" item in each session's submenu
- [x] AppleScript integration with Terminal.app
- [x] Notification click also opens terminal at session directory (via terminal-notifier)

#### 2. Auto-Clear Done Sessions (TTL)
- [x] Done sessions auto-remove after configurable delay (default 5 minutes)
- [x] `auto_clear_after_minutes` setting in JSON (0 = disabled)
- [x] Submenu to configure: Off / 2m / 5m / 15m / 30m
- [x] Runs in existing 1-second timer — no extra overhead

#### 3. Smart Notifications (terminal-notifier + osascript fallback)
- [x] Prefers `terminal-notifier` when installed — click-to-open, notification grouping, action buttons
- [x] Falls back to `osascript display notification` when terminal-notifier not available
- [x] Auto-detects at launch (checks `/opt/homebrew/bin` and `/usr/local/bin`)
- [x] Notifications fire from Swift on status transitions (not from shell hooks)
- [x] Respects `sound_enabled` setting (was previously a dead switch when hooks called terminal-notifier directly)
- [x] `install.sh` offers to install terminal-notifier, explains what it adds
- [x] Hooks no longer call terminal-notifier directly — all notifications handled by the app

#### 4. Richer Status via PostToolUse Hook
- [x] `PostToolUse` hook captures what Claude is actively doing
- [x] Activity labels: "Editing file.swift…", "Running: git status…", "Reading file…", "Searching *.ts…", "Agent: subtask…"
- [x] `activity` field on Session (separate from `summary`)
- [x] Displayed inline in menu items for running sessions
- [x] Activity cleared on new prompt or status change

#### 5. Session Grouping by Project Directory
- [x] Sessions grouped by directory in dropdown when multiple projects active
- [x] Bold section headers with directory names
- [x] Indented session items under group headers
- [x] Single-project sessions display flat (no visual change)
- [x] Menubar title stays flat (grouping only in dropdown)

#### 6. Global Keyboard Shortcut
- [x] `Cmd+Shift+A` opens AgentPulse dropdown from anywhere
- [x] Uses `NSEvent.addGlobalMonitorForEvents` + `addLocalMonitorForEvents`
- [x] Works even when menu is already open (local monitor)

#### 7. Session Cost/Token Tracking
- [x] Captures `total_input_tokens`, `total_output_tokens`, `total_cost_usd` from Stop hook
- [x] `tokens_in`, `tokens_out`, `cost_usd` fields on Session model
- [x] Displayed in session submenu: "Tokens: 45.2K in / 12.1K out" and "Cost: ~$0.42"
- [x] Compact formatting (K/M suffixes for large counts)

#### 8. Persistent Session History
- [x] Last 50 closed sessions saved to `~/.claude/session-history.json`
- [x] History submenu shows symbol, summary, directory, time ago
- [x] Click history entry to open Terminal at that directory
- [x] Records: symbol, directory, summary, timestamps, tokens, cost

#### 9. Visual Status Indicators (SF Symbols)
- [x] Colored SF Symbol icons on menu items
- [x] Running: green bolt (`bolt.fill`)
- [x] Waiting: orange pause (`pause.circle.fill`)
- [x] Done: green check (`checkmark.circle.fill`)
- [x] Images update in real-time alongside text titles

#### 10. Multi-Machine Sync
- [x] `remote_status_paths` setting — array of paths to other machines' `session-status.json`
- [x] Remote sessions displayed with `[machine]` suffix
- [x] Machine name derived from file path
- [x] Local sessions authoritative for mutations (clear/dismiss only affects local)
- [x] Polled every 1 second alongside local file

#### 11. New Branch Session (Git Worktree Integration) — superseded by v2.1 Click to Branch
- [x] ~~"New Branch Session…" menu item per project directory~~ → Removed, replaced by session row click
- [x] ~~Confirmation dialog with branch name + optional prompt fields~~ → Auto-names with animal words
- [x] ~~Creates git worktree at `<repo>/.worktrees/<branch>/`~~ → Now creates sibling dirs
- [x] ~~Auto-adds `.worktrees/` to `.gitignore`~~ → No longer needed (siblings, not nested)
- [x] Opens Terminal and runs `claude` (with prompt if provided) — one click
- [x] ~~Falls back gracefully if branch already exists~~ → Unique word selection prevents collisions
- [x] Error dialog on failure instead of silent failure

### Files Added
- `Sources/AgentPulse/NotificationManager.swift` — Smart notifications (terminal-notifier preferred, osascript fallback)
- `Sources/AgentPulse/HotkeyManager.swift` — Global Cmd+Shift+A hotkey
- `Sources/AgentPulse/SessionHistory.swift` — Persistent session history
- `Sources/AgentPulse/WorktreeManager.swift` — Git worktree creation + Claude session launcher

### Files Modified
- `Sources/AgentPulseLib/Models.swift` — Added `activity`, `tokensIn`, `tokensOut`, `costUsd`, `machine` to Session; added `autoClearAfterMinutes`, `remoteStatusPaths` to Settings
- `Sources/AgentPulseLib/DisplayLabels.swift` — Added `displayActivity()`
- `Sources/AgentPulse/StatusBarController.swift` — Click-to-open, grouping, SF symbols, token display, history menu, auto-clear submenu, hotkey integration, worktree launcher, new branch session menu
- `Sources/AgentPulse/SessionStore.swift` — TTL auto-clear, native notifications, remote session loading, `allSessions` computed property
- `Sources/AgentPulse/AppDelegate.swift` — NotificationManager setup
- `Sources/AgentPulse/Constants.swift` — Added `autoClearOptions`
- `update_status.py` — Added `extract_activity()`, `extract_cost_tokens()`, PostToolUse handling, cost/token capture
- `install.sh` — Added PostToolUse hook, moved notifications from hooks to app, restored terminal-notifier install prompt

---

## v1.0 — Initial Release

### Core App (Swift Rewrite)
- [x] SPM executable, macOS 13+, zero dependencies — single 192KB binary
- [x] NSApplication `.accessory` policy — menubar only, no Dock icon
- [x] Status bar icon with unique symbol indicators (e.g. `⏸ ◆ ⠋ ●`)
- [x] Spinner animation for running sessions (braille frames, 1s tick)
- [x] Session states: running (spinner), waiting (⏸), done (✓), sleeping (○)
- [x] Symbol-based session identity from FIFO pool of 18 unique symbols
- [x] Dropdown menu with prompt summaries, status, and "ago" durations
- [x] Dismiss individual sessions (submenu with total duration)
- [x] Clear Done Sessions (with count)
- [x] Clear All Sessions
- [x] Sound toggle (On/Off, persisted to JSON)
- [x] First-run welcome dialog (shown once, persisted)
- [x] Quit menu item (Cmd+Q)

### Data Layer
- [x] Codable JSON models (sessions + settings)
- [x] Tolerant decoding — ignores unknown fields (e.g. `skip_spaces_reminder`)
- [x] Read-then-write atomic saves (POSIX `rename()`) for settings and session removal
- [x] File watching via DispatchSource on `~/.claude/` directory (not file — atomic renames change inode)
- [x] 1-second Timer fallback for mtime polling + spinner/duration refresh (`.common` RunLoop mode — fires during menu tracking)
- [x] Shared `~/.claude/session-status.json` format — compatible with Python version

### Sort & Display
- [x] Three-tier priority sort: pinned → attention-needing → running
- [x] Within attention tier: sorted by `updated_at` ascending (longest-waiting = leftmost)
- [x] Within running tier: sorted by `started_at` ascending (stable numbering)
- [x] Consistent sort order in both menubar title and dropdown menu
- [x] Configurable max visible sessions (1–7, default 5, persisted in settings)
- [x] Overflow indicator: `…(N)` for hidden sessions

### Symbol Pool & Prompt Capture
- [x] 18-symbol FIFO pool (◆ ● ▲ ■ ★ ♠ ♣ ♥ ♦ ❀ ✚ ✦ ☀ ☽ ➤ ♪ ♫ ⚑)
- [x] Symbol assigned once per session, returned to pool on close
- [x] Stale symbol reclamation (dead PID detection)
- [x] Prompt capture from `UserPromptSubmit` hook — shows actual user prompt as summary
- [x] Short prompts (<10 chars) filtered out to avoid noise
- [x] Truncation on word boundary with `…` for long prompts
- [x] Generic placeholders (Processing..., Needs permission, etc.) fall back to directory basename
- [x] Symbol pool persisted in `session-status.json` with backward-compatible migration
- [x] Copy Path submenu item (abbreviated path copied to clipboard)

### Pin Sessions
- [x] Pin/unpin sessions via dropdown submenu (`● Pin` / `○ Unpin`)
- [x] Pinned sessions always visible regardless of max visible setting
- [x] Pinned sessions grouped in `[ ... ]` brackets in menubar title
- [x] `● ` prefix on pinned session labels in dropdown menu
- [x] Pinned list stored in `settings.pinned_sessions` (hooks never touch pin state)
- [x] Dismiss/clear correctly cleans pinned list
- [x] Pins persisted across restarts

### Session ID Keys
- [x] Sessions keyed by UUID (`session_id` from Claude CLI hooks) instead of directory path
- [x] Multiple sessions per directory supported with unique keys
- [x] Per-directory sequence numbering (`sequence_num`) assigned on first write
- [x] File lock (`fcntl.flock`) for atomic read-modify-write of session status
- [x] Hooks read `session_id` and `cwd` from stdin JSON (no backgrounding with `&`)
- [x] Fallback to directory-based key if no stdin available
- [x] Copy session ID to clipboard via dropdown submenu (`Copy ID · xxxx`)
- [x] Backward compatible — old directory-keyed sessions still display correctly

### Install / Uninstall
- [x] `install.sh` — builds binary, configures hooks, sets up LaunchAgent
- [x] Smart hook merge — skips if already exact, replaces old paths in-place, adds if missing
- [x] Detects and stops old Python menubar (`com.claude.menubar`) on install
- [x] Stops existing AgentPulse + kills manual instances before restart
- [x] Backs up `settings.json` only when actually making changes
- [x] Idempotent — safe to run multiple times
- [x] `uninstall.sh` — stops LaunchAgent, removes status file, cleans hooks from settings.json
- [x] LaunchAgent: `com.agentpulse.menubar` (coexists with Python version)
- [x] `run_update_status.sh` uses `/usr/bin/python3` (no venv dependency)

## Bugs Fixed
- [x] Session letter numbering shuffled on every hook fire (was sorted by `updated_at`, now `started_at`)
- [x] Two menubar icons when both Python and Swift versions running simultaneously
- [x] Python `install.sh` created backup spam on every run (now only on actual changes)
- [x] Python `install.sh` blindly appended duplicate hooks on re-install
- [x] Python `uninstall.sh` left orphaned hooks in settings.json
- [x] Swift `MainActor` isolation errors in Timer/DispatchSource closures
- [x] Swift `Settings` struct had `private(set)` preventing toggle_sound/first_run writes
- [x] Swift `Settings` decoding failed when new fields missing from existing JSON (added `decodeIfPresent` with defaults)
- [x] `UserNotifications` crash on unbundled binary — switched to terminal-notifier with osascript fallback

## Planned / Future
- [ ] `.app` bundle distribution (enables `UserNotifications` framework natively)
- [ ] Custom app icon
- [ ] Auto-cap menubar width based on screen size
- [ ] Fine-tune each feature based on real-world usage
- [ ] Homebrew tap for `brew install --cask agentpulse`
