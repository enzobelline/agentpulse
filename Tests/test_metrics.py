"""Unit tests for the pure-logic pieces of update_status.py.

Covers:
    - _model_family: classifies opus / sonnet / haiku / unknown
    - _context_window_for: opus → 1M, others → 200k
    - _cost_of_turn: pricing-table math against usage dicts
    - compute_context_pct: tail-read + pct extraction from a fake JSONL
    - compute_final_metrics: full-file scan finals

Run: python3 -m unittest discover tests
"""
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

# Make update_status importable from the repo root
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import update_status  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _assistant_line(model, input_t=0, out_t=0, cache_w=0, cache_r=0, ts="2026-04-22T10:00:00Z"):
    """Construct one JSONL line matching the transcript's assistant-message shape."""
    return json.dumps({
        "type": "assistant",
        "timestamp": ts,
        "message": {
            "model": model,
            "usage": {
                "input_tokens": input_t,
                "output_tokens": out_t,
                "cache_creation_input_tokens": cache_w,
                "cache_read_input_tokens": cache_r,
            },
        },
    })


def _write_jsonl_for(session_id, lines, project_dir):
    """Write a fake transcript for the given session_id into project_dir."""
    path = os.path.join(project_dir, f"{session_id}.jsonl")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path


# ---------------------------------------------------------------------------
# _model_family
# ---------------------------------------------------------------------------

class ModelFamilyTests(unittest.TestCase):
    def test_opus_variants(self):
        self.assertEqual(update_status._model_family("claude-opus-4-7"), "opus")
        self.assertEqual(update_status._model_family("claude-opus-4-6"), "opus")
        self.assertEqual(update_status._model_family("claude-opus-4-7[1m]"), "opus")

    def test_sonnet_variants(self):
        self.assertEqual(update_status._model_family("claude-sonnet-4-6"), "sonnet")
        self.assertEqual(update_status._model_family("claude-sonnet-4-5"), "sonnet")

    def test_haiku_variants(self):
        self.assertEqual(update_status._model_family("claude-haiku-4-5-20251001"), "haiku")

    def test_unknown_falls_back_to_opus(self):
        self.assertEqual(update_status._model_family("claude-something-future"), "opus")
        self.assertEqual(update_status._model_family(""), "opus")
        self.assertEqual(update_status._model_family(None), "opus")


# ---------------------------------------------------------------------------
# _context_window_for
# ---------------------------------------------------------------------------

class ContextWindowTests(unittest.TestCase):
    def test_opus_maps_to_1m(self):
        self.assertEqual(update_status._context_window_for("claude-opus-4-7"), 1_000_000)
        self.assertEqual(update_status._context_window_for("claude-opus-4-6"), 1_000_000)

    def test_sonnet_maps_to_200k(self):
        self.assertEqual(update_status._context_window_for("claude-sonnet-4-6"), 200_000)

    def test_haiku_maps_to_200k(self):
        self.assertEqual(update_status._context_window_for("claude-haiku-4-5-20251001"), 200_000)

    def test_unknown_maps_to_200k(self):
        self.assertEqual(update_status._context_window_for(""), 200_000)
        self.assertEqual(update_status._context_window_for(None), 200_000)


# ---------------------------------------------------------------------------
# _cost_of_turn
# ---------------------------------------------------------------------------

class CostOfTurnTests(unittest.TestCase):
    def test_opus_pricing_math(self):
        # Opus rates: (15, 75, 18.75, 1.50) per 1M tokens
        usage = {
            "input_tokens": 1_000_000,
            "output_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        }
        self.assertAlmostEqual(update_status._cost_of_turn(usage, "claude-opus-4-7"), 15.0)

    def test_opus_full_bundle(self):
        # 100k input + 200k output + 50k cache_write + 1M cache_read on Opus
        usage = {
            "input_tokens": 100_000,
            "output_tokens": 200_000,
            "cache_creation_input_tokens": 50_000,
            "cache_read_input_tokens": 1_000_000,
        }
        # 0.1*15 + 0.2*75 + 0.05*18.75 + 1.0*1.5 = 1.5 + 15 + 0.9375 + 1.5 = 18.9375
        self.assertAlmostEqual(
            update_status._cost_of_turn(usage, "claude-opus-4-7"),
            18.9375,
            places=4,
        )

    def test_sonnet_is_cheaper_than_opus(self):
        usage = {"input_tokens": 100_000, "output_tokens": 100_000,
                 "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
        opus = update_status._cost_of_turn(usage, "claude-opus-4-7")
        sonnet = update_status._cost_of_turn(usage, "claude-sonnet-4-6")
        self.assertGreater(opus, sonnet)

    def test_zero_tokens_zero_cost(self):
        usage = {"input_tokens": 0, "output_tokens": 0,
                 "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
        self.assertEqual(update_status._cost_of_turn(usage, "claude-opus-4-7"), 0.0)

    def test_missing_fields_default_to_zero(self):
        # Usage dict missing all token fields shouldn't crash
        self.assertEqual(update_status._cost_of_turn({}, "claude-opus-4-7"), 0.0)


# ---------------------------------------------------------------------------
# compute_context_pct
# ---------------------------------------------------------------------------

class ComputeContextPctTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._project = os.path.join(self._tmp.name, "proj")
        os.makedirs(self._project)
        self._patcher = patch.object(update_status, "PROJECTS_DIR", self._tmp.name)
        self._patcher.start()

    def tearDown(self):
        self._patcher.stop()
        self._tmp.cleanup()

    def test_opus_latest_turn_uses_1m_window(self):
        sid = "sess-opus"
        _write_jsonl_for(sid, [
            _assistant_line("claude-opus-4-7", input_t=0, cache_w=0, cache_r=100_000),
            _assistant_line("claude-opus-4-7", input_t=0, cache_w=0, cache_r=200_000),
        ], self._project)
        session = {}
        pct = update_status.compute_context_pct(sid, session)
        # 200k / 1M = 20.0
        self.assertAlmostEqual(pct, 20.0, places=1)
        self.assertEqual(session["context_window_size"], 1_000_000)

    def test_sonnet_latest_turn_uses_200k_window(self):
        sid = "sess-sonnet"
        _write_jsonl_for(sid, [
            _assistant_line("claude-sonnet-4-6", input_t=1000, cache_w=0, cache_r=50_000),
        ], self._project)
        session = {}
        pct = update_status.compute_context_pct(sid, session)
        # 51k / 200k = 25.5
        self.assertAlmostEqual(pct, 25.5, places=1)
        self.assertEqual(session["context_window_size"], 200_000)

    def test_latest_turn_wins_when_mixed(self):
        sid = "sess-mixed"
        _write_jsonl_for(sid, [
            _assistant_line("claude-sonnet-4-6", cache_r=80_000),
            _assistant_line("claude-opus-4-7", cache_r=300_000),  # latest → opus/1M
        ], self._project)
        session = {}
        pct = update_status.compute_context_pct(sid, session)
        # 300k / 1M = 30.0
        self.assertAlmostEqual(pct, 30.0, places=1)

    def test_missing_session_returns_none(self):
        session = {}
        pct = update_status.compute_context_pct("nope-not-here", session)
        self.assertIsNone(pct)

    def test_no_assistant_messages_returns_none(self):
        sid = "sess-empty"
        _write_jsonl_for(sid, [
            json.dumps({"type": "user", "content": "hi"}),
        ], self._project)
        self.assertIsNone(update_status.compute_context_pct(sid, {}))


# ---------------------------------------------------------------------------
# compute_final_metrics
# ---------------------------------------------------------------------------

class ComputeFinalMetricsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._project = os.path.join(self._tmp.name, "proj")
        os.makedirs(self._project)
        self._patcher = patch.object(update_status, "PROJECTS_DIR", self._tmp.name)
        self._patcher.start()

    def tearDown(self):
        self._patcher.stop()
        self._tmp.cleanup()

    def test_returns_expected_shape(self):
        sid = "sess-finals"
        _write_jsonl_for(sid, [
            _assistant_line("claude-opus-4-7", input_t=1000, out_t=500, cache_w=100, cache_r=50_000),
            _assistant_line("claude-opus-4-7", input_t=0, cache_r=80_000),
        ], self._project)
        result = update_status.compute_final_metrics(sid)
        self.assertIsNotNone(result)
        self.assertEqual(result["model"], "claude-opus-4-7")
        self.assertEqual(result["turn_count"], 2)
        self.assertGreater(result["final_cost"], 0)
        self.assertIsNotNone(result["final_context_pct"])

    def test_turn_count_matches_assistant_lines(self):
        sid = "sess-count"
        lines = [_assistant_line("claude-opus-4-7", cache_r=i * 1000) for i in range(5)]
        _write_jsonl_for(sid, lines, self._project)
        result = update_status.compute_final_metrics(sid)
        self.assertEqual(result["turn_count"], 5)

    def test_ignores_non_assistant_lines(self):
        sid = "sess-mixed-types"
        _write_jsonl_for(sid, [
            json.dumps({"type": "user", "content": "hi"}),
            _assistant_line("claude-opus-4-7", cache_r=10_000),
            json.dumps({"type": "system", "subtype": "meta"}),
            _assistant_line("claude-opus-4-7", cache_r=20_000),
        ], self._project)
        result = update_status.compute_final_metrics(sid)
        self.assertEqual(result["turn_count"], 2)

    def test_missing_session_returns_none(self):
        self.assertIsNone(update_status.compute_final_metrics("does-not-exist"))


if __name__ == "__main__":
    unittest.main()
