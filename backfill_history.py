#!/usr/bin/env python3
"""Backfill final_cost / model / final_context_pct / turn_count on old
history entries by reading their session JSONL transcripts.

Safe by default:
  - Dry-run unless --apply is passed
  - Atomic write (tmp + rename) when applying
  - Only fills missing fields, never overwrites existing values
  - Skips entries whose JSONL is gone — the entry is left untouched

Usage:
  python3 backfill_history.py              # dry-run, shows what would change
  python3 backfill_history.py --apply      # actually writes
"""
import json
import os
import shutil
import sys
import time

from update_status import HISTORY_FILE, compute_final_metrics


BACKUP_SUFFIX = ".pre-backfill-bak"


def plan_updates(history):
    """Return a list of (idx, entry, finals) tuples for entries needing enrichment."""
    planned = []
    for idx, entry in enumerate(history):
        # Already enriched?
        if entry.get("final_cost") is not None or entry.get("model") is not None:
            continue
        sid = entry.get("session_id")
        if not sid:
            continue
        finals = compute_final_metrics(sid)
        if not finals:
            continue
        planned.append((idx, entry, finals))
    return planned


def merge_finals(entry, finals):
    """Merge computed finals into the entry, never overwriting existing values."""
    if entry.get("final_cost") is None and finals.get("final_cost") is not None:
        entry["final_cost"] = finals["final_cost"]
    if entry.get("final_context_pct") is None and finals.get("final_context_pct") is not None:
        entry["final_context_pct"] = finals["final_context_pct"]
    if entry.get("model") is None and finals.get("model"):
        entry["model"] = finals["model"]
    if entry.get("turn_count") is None and finals.get("turn_count"):
        entry["turn_count"] = finals["turn_count"]
    return entry


def main():
    apply_changes = "--apply" in sys.argv

    if not os.path.exists(HISTORY_FILE):
        print(f"No history file at {HISTORY_FILE}")
        return

    with open(HISTORY_FILE) as f:
        history = json.load(f)

    planned = plan_updates(history)

    if not planned:
        print(f"Nothing to backfill — all {len(history)} entries either already enriched or missing transcripts.")
        return

    print(f"{'APPLY' if apply_changes else 'DRY-RUN'} — {len(planned)} / {len(history)} entries to enrich\n")
    for idx, entry, finals in planned:
        sid = entry.get("session_id", "?")[:8]
        dir_name = (entry.get("directory") or "").split("/")[-1]
        print(f"  {sid}  {dir_name[:30]:30}  model={finals.get('model')}  cost=${finals.get('final_cost'):>8.2f}  ctx={finals.get('final_context_pct')}%  turns={finals.get('turn_count')}")

    if not apply_changes:
        print("\nRerun with --apply to write these changes.")
        return

    # Back up the original
    backup = HISTORY_FILE + BACKUP_SUFFIX + f".{int(time.time())}"
    shutil.copy2(HISTORY_FILE, backup)
    print(f"\nBacked up to {backup}")

    # Merge in place
    for idx, entry, finals in planned:
        history[idx] = merge_finals(entry, finals)

    # Atomic write
    tmp = HISTORY_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(history, f, indent=4)
    os.replace(tmp, HISTORY_FILE)
    print(f"Wrote {len(planned)} updates to {HISTORY_FILE}")


if __name__ == "__main__":
    main()
