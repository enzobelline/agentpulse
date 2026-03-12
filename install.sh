#!/bin/bash
set -e

echo "=== AgentPulse Installer ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.agentpulse.menubar.plist"
OLD_LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.claude.menubar.plist"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
BINARY="$SCRIPT_DIR/.build/release/AgentPulse"

# ---------- 0. Prerequisites ----------
if ! command -v swift &>/dev/null; then
    echo "  ERROR: Swift not found. Install Xcode Command Line Tools:"
    echo "    xcode-select --install"
    exit 1
fi

# ---------- 1. Build ----------
echo "Building AgentPulse..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1 | tail -1
if [ ! -f "$BINARY" ]; then
    echo "  ERROR: Build failed."
    exit 1
fi
echo "  ✓ Build succeeded."

# ---------- 2. Stop old Python menubar if running ----------
if [ -f "$OLD_LAUNCH_AGENT" ]; then
    echo "Detected old Python menubar (com.claude.menubar)..."
    launchctl unload "$OLD_LAUNCH_AGENT" 2>/dev/null || true
    rm -f "$OLD_LAUNCH_AGENT"
    echo "  ✓ Stopped and removed old LaunchAgent."
fi

# ---------- 3. Stop existing AgentPulse if running ----------
if [ -f "$LAUNCH_AGENT" ]; then
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
    echo "  ✓ Stopped previous AgentPulse."
fi
# Also kill any manually-launched instance
pkill -f '.build/release/AgentPulse' 2>/dev/null || true

# ---------- 4. Make scripts executable ----------
chmod +x "$SCRIPT_DIR/update_status.py"
chmod +x "$SCRIPT_DIR/run_update_status.sh"
chmod +x "$SCRIPT_DIR/uninstall.sh"

# ---------- 5. Smart hook configuration ----------
echo "Configuring Claude Code hooks..."

/usr/bin/python3 - "$CLAUDE_SETTINGS" "$SCRIPT_DIR" <<'MERGE_EOF'
import json, sys, os

settings_path = sys.argv[1]
script_dir = sys.argv[2]

# Load existing settings
data = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        pass

# Desired hooks (keyed by event)
desired = {
    "SessionStart": f"{script_dir}/run_update_status.sh running --summary 'Session started'",
    "UserPromptSubmit": f"{script_dir}/run_update_status.sh running",
    "PreToolUse": f"{script_dir}/run_update_status.sh running",
    "PostToolUse": f"{script_dir}/run_update_status.sh running",
    "PostToolUseFailure": f"{script_dir}/run_update_status.sh running",
    "PermissionRequest": f"{script_dir}/run_update_status.sh waiting",
    "Stop": f"{script_dir}/run_update_status.sh done",
    "SessionEnd": f"{script_dir}/run_update_status.sh closed",
}

existing_hooks = data.get("hooks", {})
changed = False

for event, cmd in desired.items():
    new_entry = {"hooks": [{"type": "command", "command": cmd}]}
    event_list = existing_hooks.get(event, [])

    # Check if our exact hook is already present
    already_present = False
    cleaned = []
    for entry in event_list:
        cmds = [h.get("command", "") for h in entry.get("hooks", [])]
        # Is this one of ours (old or new path)?
        is_ours = any("run_update_status.sh" in c for c in cmds)
        is_exact = any(c == cmd for c in cmds)

        if is_exact:
            already_present = True
            cleaned.append(entry)
        elif is_ours:
            # Old path (e.g. claude-notifications/) — replace with ours
            cleaned.append(new_entry)
            already_present = True
            changed = True
            print(f"  ↻ {event}: replaced old hook")
        else:
            # Someone else's hook — keep it
            cleaned.append(entry)

    if not already_present:
        cleaned.append(new_entry)
        changed = True
        print(f"  + {event}: added hook")

    existing_hooks[event] = cleaned

if not changed:
    print("  ✓ Hooks already up to date.")
else:
    data["hooks"] = existing_hooks
    # Back up only when we're actually changing something
    if os.path.exists(settings_path):
        import shutil, time
        backup = f"{settings_path}.bak.{int(time.time())}"
        shutil.copy2(settings_path, backup)
        print(f"  ✓ Backed up settings to {os.path.basename(backup)}")

    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    with open(settings_path, "w") as f:
        json.dump(data, f, indent=2)
    print("  ✓ Settings saved.")
MERGE_EOF

# ---------- 6. terminal-notifier (optional, enhances notifications) ----------
if command -v terminal-notifier &>/dev/null || [ -f /opt/homebrew/bin/terminal-notifier ]; then
    echo "  ✓ terminal-notifier found — rich notifications enabled."
else
    echo "  ⚠ terminal-notifier not found — notifications will use basic osascript fallback."
    echo "    With terminal-notifier you get: action buttons, click-to-open, notification grouping."
    if command -v brew &>/dev/null || [ -f /opt/homebrew/bin/brew ]; then
        read -p "  Install it via Homebrew? [Y/n] " yn
        case "${yn:-Y}" in
            [Yy]*) brew install terminal-notifier && echo "  ✓ Installed." ;;
            *) echo "  Skipped. You can install later: brew install terminal-notifier" ;;
        esac
    else
        echo "  Install manually: brew install terminal-notifier"
    fi
fi

# ---------- 7. LaunchAgent ----------
echo "Setting up LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$LAUNCH_AGENT" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.agentpulse.menubar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/agentpulse.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/agentpulse.err</string>
</dict>
</plist>
PLIST_EOF

launchctl load "$LAUNCH_AGENT"
echo "  ✓ LaunchAgent started."

echo
echo "=== Installation Complete ==="
echo
echo "You should see ○ in your menubar."
echo
echo "Permissions (macOS will prompt on first use):"
echo "  • Automation → Terminal: Required for 'Attach to Session' and 'Open in Terminal'"
echo "    If not prompted, go to: System Settings → Privacy & Security → Automation"
echo "    and allow AgentPulse to control Terminal.app."
echo "  • Notifications: Allow when prompted for desktop notification banners."
echo
echo "Logs:   tail -f /tmp/agentpulse.log"
echo "Errors: tail -f /tmp/agentpulse.err"
echo
