# Changelog

All notable changes to AgentPulse are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

## [0.1.2] — 2026-04-23

### Added
- Real-time context-window usage (%) on every running session row, colour-coded
  green / yellow / red, tailed directly from the session transcript with
  sub-second updates.
- Session history now records cost, model, turn count, and final context % when
  a session closes.
- Workspaces tab showing per-project context / turns / duration strips,
  resolved against live state first and history finals second.
- Inline two-click confirmation for destructive actions (Clear All, Clear
  History) in place of modal dialogs.

### Changed
- Session row label now budgets space for name (up to 25 chars) plus summary
  (remaining budget, up to 65 total) so long names can no longer hide the
  summary text.
- Menu bar title is frozen while the popover is open so the popover's arrow
  stays aligned with the status item; the title refreshes immediately on
  popover close.
- Popover auto-closes on click-away in `.accessory` apps — the app is
  activated before `.show()` so `.transient` behaviour can detect outside
  clicks reliably.
- Inline rename replaces the previous NSAlert dialog for both session and
  workspace renames.
- Context-window size is now derived deterministically from the model family
  (Opus → 1M tokens, Sonnet / Haiku → 200k).
- README demo replaced with a short animated recording.

### Fixed
- Rename TextField no longer collects stray keystrokes after focus shifts
  elsewhere; input is capped at 40 characters during typing and on commit.
- "Go to Terminal" no longer aborts and falls back to a new window when a
  minimised or utility Terminal window is encountered during tab iteration.
- Session rows and the footer summary can no longer disagree on running /
  waiting / done counts; the sessions dictionary is snapshotted once per
  render and every view reads from the snapshot.

### Internal
- `composedRowLabel(displayName:summary:)` extracted to `AgentPulseLib` as a
  pure function with full unit coverage.
- 145 Swift tests and 22 Python tests passing. CI runs the full Swift suite
  plus an end-to-end install smoke test on every push.

## [0.1.1] — 2026-04-22

### Added
- Downloadable `AgentPulse.app` bundle attached to GitHub releases, built as a
  universal binary (arm64 + x86_64) and packaged with `ditto` to preserve
  macOS metadata and executable permissions.
- `configure.sh` post-install script for users of the prebuilt bundle; wires
  up Claude Code hooks and the LaunchAgent. Supports `--yes` for
  non-interactive installs.

## [0.1.0] — 2026-04-22

Initial public release.

### Added
- Menu bar status icon with a unique symbol per active session and
  spinner-animated "running" state.
- Click-to-attach: clicking a session row finds the exact Terminal tab
  running that Claude session (matched by TTY device) and brings it to the
  front across Spaces.
- Sibling-layout git worktree creation with animal-word auto-naming,
  accessible from each session's submenu.
- Session grouping by project directory; worktree sessions group with their
  parent repo and display as `word → repo`.
- Persistent session history (last 50 closed sessions) with one-click resume
  via `claude --resume`.
- Smart desktop notifications: prefers `terminal-notifier` when installed,
  falls back to `osascript`. Independent notification and sound toggles plus
  per-event sound picker with hover-to-preview.
- Global hotkey `Ctrl+Option+A` to toggle the dropdown from anywhere
  (requires Accessibility permission).
- Auto-clear TTL for done sessions (off / 5m / 15m / 30m / 1h / 3h / 1d).
- Pin sessions so they remain visible regardless of the visible-session
  limit.
- Conversational-preamble stripping on prompt summaries (e.g. "can you
  please fix the bug" → "Fix the bug").
- Multi-machine sync via `remote_status_paths` setting.
- `install.sh` with smart hook-merge (safe to re-run), and `uninstall.sh`
  that cleans up hooks and the LaunchAgent.

[0.1.2]: https://github.com/enzobelline/agentpulse/releases/tag/v0.1.2
[0.1.1]: https://github.com/enzobelline/agentpulse/releases/tag/v0.1.1
[0.1.0]: https://github.com/enzobelline/agentpulse/releases/tag/v0.1.0
