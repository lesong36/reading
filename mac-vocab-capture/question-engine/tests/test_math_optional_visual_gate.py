"""Optional visual rejection never certifies its prerequisites or blocks a valid primary."""
import copy
import json
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage
from math_skills import SkillError, SnapshotBackend, select_skills, selection_schema, snapshots_for
from test_math_skills import MESSAGES, ScriptModel, answer, skills, truth_answer
from test_math_tool_strategy import decision, read, truth_decision
from test_math_daily_applicability import daily_answer, reviewed
from test_math_selection_roles import declared_roles


class OptionalVisualGateTests(unittest.IsolatedAsyncioTestCase):
    async def run_selection(self, review, *, primary="id-0", visuals=None, protocol="daily"):
        visuals = ["id-1"] if visuals is None else visuals
        rows = skills(3)
        declared_roles(rows[0], ["solution"])
        for row in rows[1:]:
            declared_roles(row, ["visual"])
        snapshots = snapshots_for(rows)
        backend = SnapshotBackend(snapshots)
        chosen = {primary, *visuals} - {None}
        reads = [read(path, index).tool_calls[0] for index, path in enumerate(backend.files)
                 if backend.ids[path] in chosen]
        model = ScriptModel()
        model._responses = [AIMessage(content="", tool_calls=reads),
                            decision(json.loads(answer(primary, visuals))),
                            reviewed(review) if protocol == "daily" else truth_decision(review)]
        raw, details = await select_skills(model, MESSAGES, snapshots, prerequisite_protocol=protocol)
        value = json.loads(raw)
        # The final output remains valid, with precisely the accepted selection.
        selection_schema(snapshots).model_validate(value)
        return value, details, model

    async def test_failed_unknown_and_incomplete_visual_preserve_passed_primary(self):
        for truth, coverage, reason in ((False, True, "false_prerequisite"),
                                       (None, True, "unknown_prerequisite"),
                                       (True, False, "incomplete_coverage")):
            with self.subTest(reason=reason):
                review = daily_answer(visuals=["id-1"])
                review["methods"][1]["conditions"][0]["truth"] = truth
                review["methods"][1]["coverage_complete"] = coverage
                original = copy.deepcopy(review)
                value, details, model = await self.run_selection(review)
                self.assertEqual(value["method_id"], "id-0")
                self.assertEqual(value["visual_method_ids"], [])
                self.assertEqual([item["method_id"] for item in value["applicability"]], ["id-0"])
                self.assertIn("已移除对应图解", value["reason"])
                self.assertEqual(details["prerequisite_review"], {"status": "partial", "result": original,
                    "accepted_method_ids": ["id-0"],
                    "excluded_visual_methods": [{"method_id": "id-1", "reasons": [reason]}]})
                self.assertEqual(details["loaded_skill_ids"], ["id-0", "id-1"])
                self.assertEqual(len(model._calls), 3)
                self.assertNotIn("protocol_repairs", details)

    async def test_passed_visual_and_primary_remain_unchanged(self):
        review = daily_answer(visuals=["id-1"])
        value, details, _ = await self.run_selection(review)
        self.assertEqual(value, json.loads(answer("id-0", ["id-1"])))
        self.assertEqual(details["prerequisite_review"], {"status": "passed", "result": review})

    async def test_two_visuals_preserve_only_independently_passed_visual(self):
        review = daily_answer(visuals=["id-1", "id-2"])
        review["methods"][1]["conditions"][0]["truth"] = None
        value, details, _ = await self.run_selection(review, visuals=["id-1", "id-2"])
        self.assertEqual(value["visual_method_ids"], ["id-2"])
        self.assertEqual([item["method_id"] for item in value["applicability"]], ["id-0", "id-2"])
        self.assertEqual(details["prerequisite_review"]["accepted_method_ids"], ["id-0", "id-2"])
        self.assertIsNone(details["prerequisite_review"]["result"]["methods"][1]["conditions"][0]["truth"])

    async def test_unknown_additional_visual_prerequisite_is_not_upgraded(self):
        review = daily_answer(visuals=["id-1"])
        extra = {key: value for key, value in review["methods"][1]["conditions"][0].items()
                 if key != "condition_id"}
        extra.update(requirement="数量属于同一组", skill_excerpt="必须是同一组数量的和与差。", truth=None)
        review["methods"][1]["additional_prerequisites"] = [extra]
        value, details, _ = await self.run_selection(review)
        self.assertEqual(value["visual_method_ids"], [])
        self.assertEqual(details["prerequisite_review"]["result"], review)

    async def test_failed_primary_still_blocks_even_with_passed_visual(self):
        for truth, coverage in ((False, True), (None, True), (True, False)):
            review = daily_answer(visuals=["id-1"])
            review["methods"][0]["conditions"][0]["truth"] = truth
            review["methods"][0]["coverage_complete"] = coverage
            with self.assertRaises(SkillError) as caught:
                await self.run_selection(review)
            self.assertEqual(caught.exception.code, "skillsPrerequisite")
            self.assertEqual(caught.exception.details["prerequisite_review"], {"status": "blocked", "result": review})

    async def test_failed_visual_only_selection_remains_blocked(self):
        review = daily_answer(None, ["id-1"])
        review["methods"][0]["conditions"][0]["truth"] = None
        with self.assertRaises(SkillError) as caught:
            await self.run_selection(review, primary=None)
        self.assertEqual(caught.exception.code, "skillsPrerequisite")
        self.assertEqual(caught.exception.details["prerequisite_review"]["status"], "blocked")

    async def test_strict_protocol_retains_all_or_nothing_gate(self):
        review = json.loads(truth_answer("id-0", ["id-1"]))
        review["methods"][1]["conditions"][0]["truth"] = None
        with self.assertRaises(SkillError) as caught:
            await self.run_selection(review, protocol="strict")
        self.assertEqual(caught.exception.code, "skillsPrerequisite")
        self.assertEqual(caught.exception.details["prerequisite_review"], {"status": "blocked", "result": review})
