#!/bin/bash
# Post-install configurator for a downloaded AgentPulse.app.
# Wires up Claude Code hooks and the macOS LaunchAgent so the menu bar
# app starts on login and reacts to session events.
#
# Usage:
#   /Applications/AgentPulse.app/Contents/Resources/configure.sh          # interactive
#   /Applications/AgentPulse.app/Contents/Resources/configure.sh --yes    # accept defaults

set -e

AUTO_YES=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=true ;;
        -h|--help)
            echo "Usage: configure.sh [--yes]"
            echo "  --yes, -y   Accept defaults, no prompts (non-interactive)"
            exit 0
            ;;
    esac
done

# Resolve the bundle regardless of where we're invoked from
RESOURCES_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$(cd "$RESOURCES_DIR/../.." && pwd)"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentPulse"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.agentpulse.menubar.plist"
OLD_LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.claude.menubar.plist"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# Sanity check that we're actually inside an .app bundle
if [ ! -f "$APP_BINARY" ]; then
    echo "ERROR: Can't find AgentPulse binary at $APP_BINARY"
    echo "       Did you run this from inside AgentPulse.app/Contents/Resources/?"
    exit 1
fi

echo "=== AgentPulse — Configuring ==="
echo "  App bundle: $APP_BUNDLE"
echo

prompt_yn() {
    local msg="$1"
    local default="${2:-Y}"
    if $AUTO_YES; then
        return 0
    fi
    read -r -p "  $msg [${default}/n] " reply
    reply="${reply:-$default}"
    case "$reply" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

# ---------- 1. Stop old Python menubar if running ----------
if [ -f "$OLD_LAUNCH_AGENT" ]; then
    echo "Detected legacy Python menubar (com.claude.menubar)..."
    launchctl unload "$OLD_LAUNCH_AGENT" 2>/dev/null || true
    rm -f "$OLD_LAUNCH_AGENT"
    echo "  ✓ Stopped and removed old LaunchAgent."
fi

# ---------- 2. Stop running AgentPulse ----------
if [ -f "$LAUNCH_AGENT" ]; then
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
fi
pkill -f 'AgentPulse' 2>/dev/null || true

# ---------- 3. Make bundled scripts executable ----------
chmod +x "$RESOURCES_DIR/update_status.py"
chmod +x "$RESOURCES_DIR/run_update_status.sh"

# ---------- 4. Configure Claude Code hooks ----------
if prompt_yn "Add AgentPulse hooks to $CLAUDE_SETTINGS?"; then
    echo "Configuring Claude Code hooks..."
    /usr/bin/python3 - "$CLAUDE_SETTINGS" "$RESOURCES_DIR" <<'MERGE_EOF'
import json, sys, os

settings_path = sys.argv[1]
script_dir = sys.argv[2]

data = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        pass

desired = {
    "SessionStart":       f"{script_dir}/run_update_status.sh running --summary 'Session started'",
    "UserPromptSubmit":   f"{script_dir}/run_update_status.sh running",
    "PreToolUse":         f"{script_dir}/run_update_status.sh running",
    "PostToolUse":        f"{script_dir}/run_update_status.sh running",
    "PostToolUseFailure": f"{script_dir}/run_update_status.sh running",
    "PermissionRequest":  f"{script_dir}/run_update_status.sh waiting",
    "Stop":               f"{script_dir}/run_update_status.sh done",
    "SessionEnd":         f"{script_dir}/run_update_status.sh closed",
}

existing_hooks = data.get("hooks", {})
changed = False

for event, cmd in desired.items():
    new_entry = {"hooks": [{"type": "command", "command": cmd}]}
    event_list = existing_hooks.get(event, [])

    already_present = False
    cleaned = []
    for entry in event_list:
        cmds = [h.get("command", "") for h in entry.get("hooks", [])]
        is_ours = any("run_update_status.sh" in c for c in cmds)
        is_exact = any(c == cmd for c in cmds)

        if is_exact:
            already_present = True
            cleaned.append(entry)
        elif is_ours:
            cleaned.append(new_entry)
            already_present = True
            changed = True
            print(f"  ↻ {event}: replaced old hook")
        else:
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
else
    echo "  Skipped hook configuration — AgentPulse won't react to session events until hooks are added."
fi

# ---------- 5. terminal-notifier (optional) ----------
if command -v terminal-notifier &>/dev/null || [ -f /opt/homebrew/bin/terminal-notifier ]; then
    echo "  ✓ terminal-notifier found — rich notifications enabled."
else
    if command -v brew &>/dev/null || [ -f /opt/homebrew/bin/brew ]; then
        if prompt_yn "Install terminal-notifier via Homebrew for richer notifications?"; then
            brew install terminal-notifier && echo "  ✓ Installed."
        fi
    fi
fi

# ---------- 6. LaunchAgent ----------
if prompt_yn "Install LaunchAgent so AgentPulse starts on login?"; then
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
        <string>$APP_BINARY</string>
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
else
    echo "  Skipped LaunchAgent — launch AgentPulse manually from /Applications."
fi

echo
echo "=== Configuration Complete ==="
echo
echo "You should see ○ in your menubar."
echo
echo "First-run permissions (macOS will prompt as you use each feature):"
echo "  • Accessibility    — global hotkey (Ctrl+Option+A)"
echo "  • Automation (Terminal) — 'Go to Terminal' and 'Open New Session'"
echo "  • Notifications    — desktop banners"
echo
echo "Logs: tail -f /tmp/agentpulse.log"
echo "Errs: tail -f /tmp/agentpulse.err"
