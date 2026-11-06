"""Blocked method reviews retain evidence without becoming scored selections."""
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import question_engine as engine
from evaluate_teaching import attempt, summarize
from math_skills import SkillError
from langchain_core.messages import HumanMessage
from test_evaluate_teaching import CountingModel
from test_math_skills import declared_policy
from math_skills import snapshots_for


class PrerequisiteReportingTests(unittest.IsolatedAsyncioTestCase):
    def review(self):
        return {"mode": "deepagents_skills", "model_calls": 3,
                "prerequisite_review": {"status": "blocked", "result": {"methods": [
                    {"method_id": "a", "coverage_complete": True,
                     "conditions": [{"condition_id": "p1", "truth": False,
                                     "evidence": "题目条件否定必要前提"}],
                     "additional_prerequisites": []}]}}}

    async def test_native_error_event_keeps_only_structured_block_evidence(self):
        events = []
        error = SkillError("skillsPrerequisite", details=self.review())
        with patch.object(engine, "stream_answer", side_effect=error):
            await engine.run_request({"id": "request", "task": "math_method_selection"}, events.append)
        self.assertEqual(events, [{"id": "request", "type": "error", "code": "skillsPrerequisite",
                                  "selection_review": self.review()}])
        self.assertNotIn("method_id", events[0])
        self.assertNotIn("message", events[0])

    async def test_native_protocol_error_preserves_only_allowlisted_issue(self):
        for issue in ("review.methods[0].additional_prerequisites:missing_field",
                      "review.methods[0].conditions[0].arithmetic:expression"):
            events = []
            with patch.object(engine, "stream_answer", side_effect=SkillError("skillsOutput", issue=issue)):
                await engine.run_request({"id": "request"}, events.append)
            self.assertEqual(events, [{"id": "request", "type": "error", "code": "skillsOutput",
                                       "selection_issue": issue}])

    async def test_native_protocol_error_discards_arbitrary_provider_detail(self):
        events = []
        with patch.object(engine, "stream_answer", side_effect=SkillError("skillsOutput", issue="private-key-model-argument")):
            await engine.run_request({"id": "request"}, events.append)
        self.assertEqual(events, [{"id": "request", "type": "error", "code": "skillsOutput"}])

    async def test_evaluation_block_is_not_a_correct_null_selection(self):
        item = {"id": "a", "version_id": "v", "title": "完整计数", "category": "计数",
                "instructions": "总数须能整除每组数量"}
        item["teaching_policy"] = declared_policy(item)
        model = CountingModel()
        with patch("evaluate_teaching.select_skills", side_effect=SkillError(
                "skillsPrerequisite", details=self.review())):
            result = await attempt(model, [HumanMessage("请不用方程")], snapshots_for([item]),
                                   {"expected_methods": [], "forbidden_methods": ["a"]}, "framework", 10)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["execution"], self.review())
        self.assertNotIn("decision", result)
        self.assertNotIn("score", result)
        summary = summarize([{"framework": result}])["framework"]
        self.assertEqual(summary["attempted"], 1)
        self.assertEqual(summary["prerequisite_blocks"], 1)
        self.assertEqual(summary["valid"], 0)
        self.assertEqual(summary["failed"], 1)
        self.assertEqual(summary["primary_match_rate_over_attempts"], 0)
        self.assertIsNone(model.callbacks)


if __name__ == "__main__":
    unittest.main()
