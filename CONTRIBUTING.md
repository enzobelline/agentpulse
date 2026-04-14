# Contributing to AgentPulse

Thanks for your interest in contributing! AgentPulse is a native macOS menubar app for monitoring Claude Code sessions, and we welcome contributions from the community.

## Getting Started

```bash
git clone https://github.com/enzobelline/agentpulse_swift.git
cd agentpulse_swift
swift build -c release    # compiles the app binary
swift test                # runs 145 tests across 7 suites
```

Requirements:
- macOS 15+ (Sequoia or later)
- Swift 6.0+ — included with Xcode Command Line Tools. Check with `swift --version`. If you don't have it: `xcode-select --install`

## Architecture

AgentPulse is split into two Swift targets:

- **AgentPulseLib** — Pure logic with no AppKit dependencies. Models, sorting, display labels, session reaping, worktree helpers, attach routing. This is where testable business logic lives.
- **AgentPulse** — AppKit layer. StatusBarController (menu UI), SessionStore (file watching, JSON I/O), NotificationManager, WorktreeManager. These depend on macOS APIs and are harder to unit test.

The pattern: extract pure functions into AgentPulseLib, test them thoroughly, keep AppKit code thin.

### Hook Pipeline

```
Claude Code hook event
  -> run_update_status.sh (captures TTY via $PPID)
    -> update_status.py (reads stdin JSON, writes ~/.claude/session-status.json)
      -> AgentPulse detects file change via DispatchSource
        -> UI updates
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed data flows and design decisions.

## Development Workflow

1. Make your changes
2. Run `swift test` — all 145+ tests must pass
3. Build and test manually: `swift build -c release && pkill -f AgentPulse`
   (LaunchAgent auto-restarts with the new binary)
4. Open the menubar dropdown, verify your change works

## Writing Tests

We use Swift Testing (`@Test`, `#expect`), not XCTest.

```swift
import Testing
@testable import AgentPulseLib

@Test("Description of what you're testing")
func myTest() {
    let result = someFunction(input)
    #expect(result == expected)
}
```

Tests go in `Tests/AgentPulseTests/`. Name the file after the feature: `MyFeatureTests.swift`.

## Pull Requests

- Keep PRs focused — one feature or fix per PR
- Include tests for new logic (especially if it can go in AgentPulseLib)
- Run `swift test` before submitting
- Describe what changed and why in the PR description
- If it changes UI behavior, describe how to manually verify

## Code Style

No linter configured yet. Follow existing patterns:
- `@MainActor` for anything touching AppKit
- `nonisolated` for delegate callbacks that need `MainActor.assumeIsolated`
- Pure functions in AgentPulseLib, side effects in AgentPulse
- Minimal comments — only where the "why" isn't obvious

## Areas Where Help is Wanted

Check [issues labeled `help wanted`](https://github.com/enzobelline/agentpulse_swift/labels/help%20wanted) for current opportunities. Some bigger areas:

- **iTerm2 / Warp support** — attach to sessions in terminals other than Terminal.app
- **Homebrew formula** — package for easy distribution
- **App bundle** — proper .app with code signing for Gatekeeper and permissions
- **Linux port** — systray equivalent, different file watching

## Reporting Bugs

Open an issue with:
- macOS version
- How you installed AgentPulse
- Steps to reproduce
- What you expected vs what happened
- Output from `tail -20 /tmp/agentpulse.err` if relevant

## Code of Conduct

This project follows the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Please be respectful and constructive in all interactions.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
