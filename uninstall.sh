#!/bin/bash
set -e

echo "=== AgentPulse Uninstaller ==="
echo

LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.agentpulse.menubar.plist"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# ---------- 1. Stop and remove LaunchAgent ----------
if [ -f "$LAUNCH_AGENT" ]; then
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT"
    echo "✓ Removed LaunchAgent."
else
    echo "  LaunchAgent not found (already removed)."
fi

# Kill any manually-launched instance
pkill -f '.build/release/AgentPulse' 2>/dev/null || true

# ---------- 2. Remove status file ----------
if [ -f "$HOME/.claude/session-status.json" ]; then
    rm -f "$HOME/.claude/session-status.json"
    echo "✓ Removed status file."
fi

# ---------- 3. Clean hooks from settings.json ----------
if [ -f "$CLAUDE_SETTINGS" ]; then
    echo "Cleaning hooks from settings.json..."
    /usr/bin/python3 - "$CLAUDE_SETTINGS" <<'CLEAN_EOF'
import json, sys, os

settings_path = sys.argv[1]

try:
    with open(settings_path, "r") as f:
        data = json.load(f)
except (json.JSONDecodeError, IOError):
    print("  Could not read settings.")
    sys.exit(0)

hooks = data.get("hooks", {})
changed = False

for event in list(hooks.keys()):
    event_list = hooks[event]
    cleaned = []
    for entry in event_list:
        cmds = [h.get("command", "") for h in entry.get("hooks", [])]
        if any("run_update_status.sh" in c for c in cmds):
            changed = True
            print(f"  - {event}: removed hook")
        else:
            cleaned.append(entry)
    if cleaned:
        hooks[event] = cleaned
    else:
        del hooks[event]

if changed:
    data["hooks"] = hooks
    with open(settings_path, "w") as f:
        json.dump(data, f, indent=2)
    print("  ✓ Hooks removed from settings.")
else:
    print("  No hooks to remove.")
CLEAN_EOF
fi

echo
echo "=== Uninstallation Complete ==="
echo
echo "Backups of settings.json (if any) are in ~/.claude/"
echo
