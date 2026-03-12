#!/bin/bash
# Wrapper to run update_status.py using system Python3
DIR="$(cd "$(dirname "$0")" && pwd)"
# Capture TTY for session-attach feature. The hook's own stdin is piped JSON
# (not a tty), so we look up the TTY of our parent process (Claude CLI)
# which is connected to the Terminal tab.
export AGENTPULSE_TTY=$(ps -p $PPID -o tty= 2>/dev/null)
exec /usr/bin/python3 "$DIR/update_status.py" "$@"
