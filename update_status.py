#!/usr/bin/env python3
"""Hook helper - updates session status in ~/.claude/session-status.json."""

import fcntl
import json
import os
import sys
import time

STATUS_FILE = os.path.expanduser("~/.claude/session-status.json")
HISTORY_FILE = os.path.expanduser("~/.claude/session-history.json")
SHADOW_FILE = os.path.expanduser("~/.claude/session-shadow.json")
MAX_HISTORY = 50
SHADOW_MAX_AGE = 86400  # 24 hours

DEFAULT_SYMBOLS = [
    "◆", "●", "▲", "■", "★",
    "♠", "♣", "♥", "♦",
    "✚", "✦", "☀", "☽", "➤", "♪", "♫",
]


def read_stdin_json():
    """Read the JSON payload Claude Code passes via stdin to hooks."""
    try:
        if not sys.stdin.isatty():
            return json.load(sys.stdin)
    except (json.JSONDecodeError, IOError):
        pass
    return {}


def next_sequence_num(sessions, directory):
    """Assign the next sequence number for sessions sharing a directory."""
    existing = [
        s.get("sequence_num", 0)
        for s in sessions.values()
        if s.get("directory") == directory
    ]
    return max(existing, default=-1) + 1


def _is_pid_alive(pid):
    """Check if a process is still running."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def assign_symbol(data, session_key):
    """Pop a symbol from the front of the available pool and assign it.

    Reclaims symbols from dead sessions first. Returns "?" if exhausted.
    """
    pool = data.setdefault("symbol_pool", {
        "available": list(DEFAULT_SYMBOLS),
        "assigned": {},
    })

    # Already assigned?
    if session_key in pool["assigned"]:
        return pool["assigned"][session_key]

    # Reclaim symbols from sessions that no longer exist or have dead PIDs
    sessions = data.get("sessions", {})
    stale_keys = []
    for key, sym in list(pool["assigned"].items()):
        if key not in sessions:
            stale_keys.append(key)
        elif key != session_key:
            pid = sessions[key].get("pid")
            if pid and not _is_pid_alive(pid):
                stale_keys.append(key)

    for key in stale_keys:
        sym = pool["assigned"].pop(key)
        if sym not in pool["available"]:
            pool["available"].append(sym)

    if not pool["available"]:
        return "?"

    symbol = pool["available"].pop(0)
    pool["assigned"][session_key] = symbol
    return symbol


def release_symbol(data, session_key):
    """Return a session's symbol to the back of the available pool."""
    pool = data.get("symbol_pool")
    if not pool:
        return
    sym = pool["assigned"].pop(session_key, None)
    if sym and sym not in pool["available"]:
        pool["available"].append(sym)


def _load_shadow():
    """Load the shadow file. Returns dict of session_key → fields."""
    if os.path.exists(SHADOW_FILE):
        try:
            with open(SHADOW_FILE, "r") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return {}


def _save_shadow(shadow):
    """Write shadow file atomically."""
    tmp = SHADOW_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(shadow, f, indent=2)
    os.replace(tmp, SHADOW_FILE)


def update_shadow(session_key, fields):
    """Merge fields into a session's shadow entry. Prunes stale entries."""
    shadow = _load_shadow()
    entry = shadow.get(session_key, {})
    entry.update(fields)
    entry["_updated"] = time.time()
    shadow[session_key] = entry
    # Prune entries older than 24h
    now = time.time()
    shadow = {k: v for k, v in shadow.items()
              if now - v.get("_updated", 0) < SHADOW_MAX_AGE}
    _save_shadow(shadow)


def pop_shadow(session_key):
    """Read and remove a session's shadow entry. Returns the entry or {}."""
    shadow = _load_shadow()
    entry = shadow.pop(session_key, {})
    entry.pop("_updated", None)
    _save_shadow(shadow)
    return entry


def record_to_history(session, session_key, now):
    """Write a session to the history file (dedup by session_id)."""
    entry = {
        "symbol": session.get("symbol", "?"),
        "directory": session.get("directory", ""),
        "summary": session.get("summary", ""),
        "session_id": session_key,
        "started_at": session.get("started_at", now),
        "ended_at": now,
    }
    last_msg = session.get("last_message")
    if last_msg:
        entry["last_message"] = last_msg
    # Read existing history
    history = []
    if os.path.exists(HISTORY_FILE):
        try:
            with open(HISTORY_FILE, "r") as f:
                history = json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    # Dedup: skip if session_id already in history
    if any(h.get("session_id") == session_key for h in history):
        return
    # Prepend and cap
    history = [entry] + history
    if len(history) > MAX_HISTORY:
        history = history[:MAX_HISTORY]
    # Write atomically
    tmp = HISTORY_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(history, f, indent=4)
    os.replace(tmp, HISTORY_FILE)


def extract_activity(stdin_data):
    """Extract activity description from a PostToolUse hook payload.

    Returns a short string like "Editing Models.swift…" or "Running bash…".
    """
    if stdin_data.get("hook_event_name") != "PostToolUse":
        return None

    tool_name = stdin_data.get("tool_name", "")
    tool_input = stdin_data.get("tool_input", {})

    if tool_name == "Bash":
        cmd = tool_input.get("command", "")
        short = cmd.split("\n")[0][:30] if cmd else "command"
        return f"Running: {short}…"
    elif tool_name == "Edit":
        path = tool_input.get("file_path", "")
        fname = os.path.basename(path) if path else "file"
        return f"Editing {fname}…"
    elif tool_name == "Write":
        path = tool_input.get("file_path", "")
        fname = os.path.basename(path) if path else "file"
        return f"Writing {fname}…"
    elif tool_name == "Read":
        path = tool_input.get("file_path", "")
        fname = os.path.basename(path) if path else "file"
        return f"Reading {fname}…"
    elif tool_name == "Glob":
        pattern = tool_input.get("pattern", "files")
        return f"Searching {pattern}…"
    elif tool_name == "Grep":
        pattern = tool_input.get("pattern", "")
        return f"Grepping {pattern[:20]}…"
    elif tool_name == "Task":
        desc = tool_input.get("description", "subtask")
        return f"Agent: {desc[:25]}…"
    elif tool_name == "WebSearch":
        query = tool_input.get("query", "")
        return f"Searching: {query[:20]}…"
    elif tool_name:
        return f"Using {tool_name}…"
    return None


def _strip_preamble(text):
    """Strip conversational preamble to get to the meaningful action.

    Sorted longest-first so "can you please" matches before "can you".
    Only strips one prefix (the first match). Case-insensitive.
    """
    prefixes = [
        # Multi-word polite/conversational
        "i would like you to ", "i would like to ",
        "would you please ", "could you please ", "can you please ",
        "i was wondering if you could ", "i was wondering if ",
        "let's go ahead and ", "go ahead and ",
        "i want you to ", "i need you to ",
        "i'd like you to ", "i'd like to ",
        "do you think you could ", "do you think we could ",
        "do you think you can ", "do you think we can ",
        "would you mind ", "could you also ",
        "i want to ", "i need to ",
        "would you ", "could you ", "can you ",
        "we should ", "we need to ", "we want to ",
        "let's also ", "let's just ", "let's ",
        "let us also ", "let us just ", "let us ",
        "please also ", "please just ", "please ",
        "also please ", "also can you ", "also ",
        "now let's ", "now can you ", "now please ", "now ",
        "next let's ", "next can you ", "next please ", "next ",
        "then let's ", "then can you ", "then please ", "then ",
        # Acknowledgements / transitions
        "sounds good ", "sounds good, ",
        "that sounds good ", "that sounds good, ",
        "that works ", "that works, ",
        "perfect ", "perfect, ",
        "great ", "great, ", "great! ",
        "awesome ", "awesome, ", "awesome! ",
        "nice ", "nice, ", "nice! ",
        "cool ", "cool, ", "cool! ",
        "alright ", "alright, ",
        "sure ", "sure, ", "sure! ",
        "thanks ", "thanks, ", "thanks! ",
        "thank you ", "thank you, ",
        "got it ", "got it, ",
        "understood ", "understood, ",
        # Short affirmations/negations
        "yeah ", "yeah, ", "yeah! ",
        "yes ", "yes, ", "yes! ",
        "yep ", "yep, ", "yep! ",
        "yup ", "yup, ", "yup! ",
        "no ", "no, ",
        "nah ", "nah, ",
        "nope ", "nope, ",
        "ok ", "ok, ", "ok! ",
        "okay ", "okay, ", "okay! ",
        "so ", "so, ",
        # Greetings / interjections
        "hey ", "hey, ",
        "hi ", "hi, ",
        "hmm ", "hmm, ",
        "well ", "well, ",
        "right ", "right, ",
        "actually ", "actually, ",
        "anyway ", "anyway, ",
        "basically ", "basically, ",
        # Filler starters
        "i think we should ", "i think you should ", "i think ",
        "i guess ", "i suppose ",
        "just ", "maybe ", "perhaps ",
        "help me ", "help us ",
    ]
    # Strip repeatedly (handles chained preamble like "yeah, let's go ahead and")
    changed = True
    while changed:
        changed = False
        lower = text.lower()
        for prefix in prefixes:
            if lower.startswith(prefix):
                text = text[len(prefix):]
                changed = True
                break
    return text


def extract_prompt_summary(stdin_data):
    """Extract a display summary from a UserPromptSubmit hook payload.

    Returns None if the prompt is too short (<10 chars) or not present.
    Strips conversational preamble, then truncates to ~40 chars on a word
    boundary with '…'.
    """
    if stdin_data.get("hook_event_name") != "UserPromptSubmit":
        return None

    prompt = stdin_data.get("prompt", "").strip()
    if not prompt:
        return None

    # Strip preamble to get to the action
    prompt = _strip_preamble(prompt)

    if not prompt:
        return None

    # Capitalize first letter
    prompt = prompt[0].upper() + prompt[1:]

    if len(prompt) <= 40:
        return prompt

    # Truncate on word boundary
    truncated = prompt[:40]
    last_space = truncated.rfind(" ")
    if last_space > 20:
        truncated = truncated[:last_space]
    return truncated + "…"


def update_status(status, summary=None, stdin_data=None):
    """Update the status for the current session (keyed by session_id)."""
    if stdin_data is None:
        stdin_data = {}

    session_key = stdin_data.get("session_id") or os.environ.get("TERM_SESSION_ID") or os.getcwd()
    # cwd is refreshed on every hook event — always the session's current working
    # directory, not necessarily where it was launched from. Drives: grouping headers,
    # fallback summary label, worktree lineage display, Open in Terminal, Click to Branch.
    cwd = stdin_data.get("cwd") or os.getcwd()
    name = os.path.basename(cwd)
    pid = os.getppid()

    # Capture the TTY for session-attach. The shell wrapper passes it via env var
    # since hooks are backgrounded (&) which detaches from the process tree.
    tty_path = None
    tty_env = os.environ.get("AGENTPULSE_TTY", "").strip()
    if tty_env and tty_env not in ("??", "?", "not a tty", ""):
        tty_path = f"/dev/{tty_env}"

    # Ensure directory exists
    os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)

    # Use file lock for atomic read-modify-write
    lock_path = STATUS_FILE + ".lock"
    with open(lock_path, "w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
            # Load existing data
            data = {"sessions": {}, "settings": {}}
            if os.path.exists(STATUS_FILE):
                try:
                    with open(STATUS_FILE, "r") as f:
                        data = json.load(f)
                except (json.JSONDecodeError, IOError):
                    pass

            sessions = data.get("sessions", {})

            # Dedup by TTY: if another session owns this TTY, it's stale
            # (e.g. user exited and resumed in the same terminal tab)
            if tty_path and status != "closed":
                for key in list(sessions.keys()):
                    if key != session_key and sessions[key].get("tty") == tty_path:
                        release_symbol(data, key)
                        sessions.pop(key)

            if status == "closed":
                # Read session data from shadow file — independent of
                # the status file which the Swift reaper may have already cleared.
                shadow_data = pop_shadow(session_key)
                now = time.time()
                # Merge: shadow data is authoritative, fill gaps from status file
                file_session = sessions.get(session_key, {})
                session = {**file_session, **shadow_data}
                # Backfill minimum fields
                if "directory" not in session:
                    session["directory"] = cwd
                if "name" not in session:
                    session["name"] = name
                if "started_at" not in session:
                    session["started_at"] = now
                if "symbol" not in session:
                    session["symbol"] = assign_symbol(data, session_key)
                # Write to history if session has a real summary
                summary_val = session.get("summary")
                placeholders = {"Processing...", "Needs permission", "Session started", "Process ended", "Finished"}
                if summary_val and summary_val not in placeholders:
                    record_to_history(session, session_key, now)
                # Remove session from status file (and release symbol)
                sessions.pop(session_key, None)
                release_symbol(data, session_key)
            else:
                session = sessions.get(session_key, {})
                session["directory"] = cwd
                session["name"] = name
                session["status"] = status
                session["updated_at"] = time.time()
                session["pid"] = pid
                if tty_path:
                    session["tty"] = tty_path
                if "started_at" not in session:
                    session["started_at"] = session["updated_at"]
                if "sequence_num" not in session:
                    session["sequence_num"] = next_sequence_num(sessions, cwd)

                # Assign a symbol once per session
                if "symbol" not in session:
                    session["symbol"] = assign_symbol(data, session_key)

                # Activity capture from PostToolUse
                activity = extract_activity(stdin_data)
                if activity:
                    session["activity"] = activity
                elif status != "running":
                    session.pop("activity", None)

                # Last assistant message capture from Stop
                last_msg = stdin_data.get("last_assistant_message")
                if last_msg and isinstance(last_msg, str):
                    # Truncate to ~200 chars for storage
                    if len(last_msg) > 200:
                        last_msg = last_msg[:200].rsplit(" ", 1)[0] + "…"
                    session["last_message"] = last_msg

                # Prompt capture from UserPromptSubmit
                prompt_summary = extract_prompt_summary(stdin_data)
                if prompt_summary:
                    session["summary"] = prompt_summary
                    session.pop("activity", None)  # Clear activity on new prompt
                elif summary:
                    session["summary"] = summary
                elif "summary" not in session or session.get("summary") in (
                    "Processing...", "Needs permission", None
                ):
                    # Only set generic summaries if no meaningful one exists
                    if status == "running":
                        session["summary"] = "Processing..."
                    elif status == "waiting":
                        session["summary"] = "Needs permission"
                    elif status == "done" and session.get("summary") in (None, "Processing...", "Needs permission"):
                        session["summary"] = "Finished"

                sessions[session_key] = session

                # Update shadow file for history recording (skip high-frequency tool events — no history data)
                hook_event = stdin_data.get("hook_event_name", "")
                if hook_event not in ("PostToolUse", "PreToolUse", "PostToolUseFailure"):
                    shadow_fields = {
                        "directory": session.get("directory", cwd),
                        "name": session.get("name", name),
                        "started_at": session.get("started_at"),
                    }
                    sym = session.get("symbol")
                    if sym:
                        shadow_fields["symbol"] = sym
                    s = session.get("summary")
                    if s:
                        shadow_fields["summary"] = s
                    lm = session.get("last_message")
                    if lm:
                        shadow_fields["last_message"] = lm
                    update_shadow(session_key, shadow_fields)

            data["sessions"] = sessions

            # Write atomically
            tmp_file = STATUS_FILE + ".tmp"
            with open(tmp_file, "w") as f:
                json.dump(data, f, indent=2)
            os.replace(tmp_file, STATUS_FILE)
        finally:
            fcntl.flock(lock_file, fcntl.LOCK_UN)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: update_status.py <status> [--summary <text>]", file=sys.stderr)
        sys.exit(1)

    # Read stdin JSON from Claude Code hooks
    stdin_data = read_stdin_json()

    status = sys.argv[1]
    summary = None

    if "--summary" in sys.argv:
        idx = sys.argv.index("--summary")
        if idx + 1 < len(sys.argv):
            summary = sys.argv[idx + 1]

    update_status(status, summary, stdin_data)
