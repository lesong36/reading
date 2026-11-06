"""Truth protocol gates do not certify the model's mathematical judgments."""
import asyncio
import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage
from math_skills import SkillError, SnapshotBackend, prerequisite_requirements, prerequisite_schema, select_skills, snapshots_for
from test_math_skills import MESSAGES, ScriptModel, answer, skills, truth_answer
from test_math_tool_strategy import decision, read, truth_decision


class PrerequisiteSchemaTests(unittest.TestCase):
    def setUp(self):
        self.snapshots = snapshots_for(skills())
        self.requirements = prerequisite_requirements(json.loads(answer()))
        self.schema = prerequisite_schema(self.requirements, self.snapshots[:1])

    def test_fixed_ids_include_requirements_only_and_truth_is_strict_boolean_nullable(self):
        self.assertEqual(self.requirements, [{"method_id": "id-0", "conditions": [
            {"condition_id": "p1", "requirement": "同一对数量给出和与差"}]}])
        for truth in (True, False, None):
            value = json.loads(truth_answer(truth=truth))
            self.assertEqual(self.schema.model_validate(value).model_dump(), value)
        for truth in (1, 0, "true", "false", {}, []):
            with self.subTest(truth=truth), self.assertRaises(ValueError):
                self.schema.model_validate(json.loads(truth_answer(truth=truth)))
        published = self.schema.model_json_schema()
        self.assertEqual(published["required"], ["methods"])
        self.assertFalse(published["additionalProperties"])

    def test_exact_method_and_fixed_condition_coverage_rejects_invented_missing_duplicate(self):
        original = json.loads(truth_answer())
        mutations = []
        for ids in ([], ["p1", "p1"], ["p2"]):
            value = copy.deepcopy(original)
            value["methods"][0]["conditions"] = [{"condition_id": id, "proposition": "原题满足同组前提", "basis": "fact", "arithmetic": None, "truth": True, "evidence": "原图事实"} for id in ids]
            mutations.append(value)
        value = copy.deepcopy(original); value["methods"] *= 2; mutations.append(value)
        value = copy.deepcopy(original); value["methods"][0]["method_id"] = "id-1"; mutations.append(value)
        value = copy.deepcopy(original); value["methods"] = []; mutations.append(value)
        value = copy.deepcopy(original); value["methods"][0]["conditions"][0]["evidence"] = "  "; mutations.append(value)
        for value in mutations:
            with self.subTest(value=value), self.assertRaises((SkillError, ValueError)):
                self.schema.model_validate(value)

    def test_additional_prerequisite_requires_actual_body_excerpt_and_bounded_output(self):
        value = json.loads(truth_answer())
        extra = {"requirement": "必须同组", "skill_excerpt": "必须是同一组数量的和与差。", "proposition": "原题满足同组前提", "basis": "fact", "arithmetic": None, "truth": True, "evidence": "原图两量一致", "scope": "required", "guard_excerpt": None, "guard_trigger_excerpt": None, "guard_proposition": None, "guard_truth": None, "guard_evidence": None}
        value["methods"][0]["additional_prerequisites"] = [extra]
        self.assertEqual(self.schema.model_validate(value).model_dump(), value)
        for change in ({"skill_excerpt": "伪造摘录"}, {"evidence": " "}, {"requirement": " "}, {"truth": 1}, {"skill_excerpt": "大" * 601}):
            invalid = copy.deepcopy(value); invalid["methods"][0]["additional_prerequisites"][0].update(change)
            with self.subTest(change=change), self.assertRaises((SkillError, ValueError)):
                self.schema.model_validate(invalid)
        value["methods"][0]["additional_prerequisites"] *= 2
        with self.assertRaises(SkillError): self.schema.model_validate(value)
        huge = {"methods": [{"irrelevant": "大" * 6000}]}
        with self.assertRaises(SkillError) as captured: self.schema.model_validate(huge)
        self.assertEqual(captured.exception.issue, "selection.payload:limit")


class PrerequisiteGraphTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.snapshots = snapshots_for(skills())
        self.path = next(iter(SnapshotBackend(self.snapshots).files))

    async def test_multiple_selected_methods_are_independently_covered_without_unselected_bodies(self):
        paths = list(SnapshotBackend(self.snapshots).files)
        model = ScriptModel(); model._responses = [AIMessage(content="", tool_calls=[read(path, i).tool_calls[0] for i, path in enumerate(paths)]),
            decision(json.loads(answer("id-0", ["id-1"]))), truth_decision(json.loads(truth_answer("id-0", ["id-1"])))]
        raw, details = await select_skills(model, MESSAGES, self.snapshots)
        self.assertEqual(json.loads(raw), json.loads(answer("id-0", ["id-1"])))
        self.assertEqual(len(details["prerequisite_review"]["result"]["methods"]), 2)
        self.assertEqual(model._bindings[-1][0], ["PrerequisiteTruth"])

    async def test_false_additional_prerequisite_blocks_without_modifying_draft_or_retrying(self):
        for truth in (False, None):
            reviewed = json.loads(truth_answer())
            reviewed["methods"][0]["additional_prerequisites"] = [{"requirement": "同一组数量", "skill_excerpt": "必须是同一组数量的和与差。", "proposition": "原图给出同组信息", "basis": "fact", "arithmetic": None, "truth": truth, "evidence": "题面不支持同组", "scope": "required", "guard_excerpt": None, "guard_trigger_excerpt": None, "guard_proposition": None, "guard_truth": None, "guard_evidence": None}]
            model = ScriptModel(); model._responses = [read(self.path), decision(), truth_decision(reviewed), truth_decision()]
            with self.assertRaises(SkillError) as captured:
                await select_skills(model, MESSAGES, self.snapshots)
            self.assertEqual(captured.exception.code, "skillsPrerequisite")
            self.assertEqual(captured.exception.details["prerequisite_review"]["result"], reviewed)
            self.assertEqual(len(model._calls), 3); self.assertEqual(len(model._responses), 1)
            self.assertNotIn("selection", captured.exception.details)

    async def test_truth_truncation_repairs_once_for_text_and_output_tool(self):
        for invalid in (AIMessage(truth_answer(), response_metadata={"finish_reason": "length"}),
            truth_decision(finish_reason="length"), truth_decision(status="incomplete")):
            model = ScriptModel(); model._responses = [read(self.path), decision(), invalid, truth_decision()]
            raw, details = await select_skills(model, MESSAGES, self.snapshots)
            self.assertEqual(json.loads(raw), json.loads(answer()))
            self.assertEqual(details["protocol_repairs"], ["selection.json:incomplete"])
            self.assertEqual(details["model_calls"], 4)

    async def test_malformed_text_and_tool_review_share_single_repair(self):
        invalid = json.loads(truth_answer()); del invalid["methods"][0]["coverage_complete"]
        for first, second in ((AIMessage(json.dumps(invalid)), truth_decision(invalid)), (truth_decision(invalid), AIMessage(json.dumps(invalid)))):
            model = ScriptModel(); model._responses = [read(self.path), decision(), first, second, truth_decision()]
            with self.assertRaises(SkillError): await select_skills(model, MESSAGES, self.snapshots)
            self.assertEqual(len(model._calls), 4); self.assertEqual(len(model._responses), 1)

    async def test_forged_excerpt_and_condition_mismatch_cannot_escape_with_repair(self):
        for mutate in ("excerpt", "duplicate", "missing"):
            invalid = json.loads(truth_answer())
            if mutate == "excerpt":
                invalid["methods"][0]["additional_prerequisites"] = [{"requirement": "同组", "skill_excerpt": "伪造全文", "proposition": "原题满足同组前提", "basis": "fact", "arithmetic": None, "truth": True, "evidence": "声称已满足", "scope": "required", "guard_excerpt": None, "guard_trigger_excerpt": None, "guard_proposition": None, "guard_truth": None, "guard_evidence": None}]
            elif mutate == "duplicate": invalid["methods"][0]["conditions"] *= 2
            else: invalid["methods"][0]["conditions"][0]["condition_id"] = "p2"
            model = ScriptModel(); model._responses = [read(self.path), decision(), truth_decision(invalid), truth_decision(invalid), truth_decision()]
            with self.assertRaises(SkillError): await select_skills(model, MESSAGES, self.snapshots)
            self.assertEqual(len(model._calls), 4); self.assertEqual(len(model._responses), 1)

    async def test_explicit_truth_tool_rejection_uses_visible_counted_json_compatibility(self):
        class Unsupported(Exception):
            status_code = 400
            body = {"error": {"param": "tools", "message": "tools unsupported"}}
        model = ScriptModel(); model._responses = [read(self.path), decision(), Unsupported(), AIMessage(truth_answer())]
        raw, details = await select_skills(model, MESSAGES, self.snapshots)
        self.assertEqual(json.loads(raw)["method_id"], "id-0")
        self.assertEqual(details["fallback_reason"], "prerequisite_tool_protocol_unsupported")
        self.assertEqual(details["loaded_skill_ids"], ["id-0"])
        self.assertEqual(details["model_calls"], 4)
        self.assertEqual(details["prerequisite_review"]["status"], "passed")
        self.assertIn("JSON兼容", json.loads(raw)["reason"])

    async def test_raw_compatibility_duplicate_keys_and_prose_are_rejected(self):
        original = truth_answer()
        invalids = [original.replace('"truth": true', '"truth": false, "truth": true'),
            original.replace('"coverage_complete": true', '"coverage_complete": false, "coverage_complete": true'),
            "说明\n" + original, original + "\n" + original]
        for invalid in invalids:
            model = ScriptModel(); model._unsupported = True
            model._responses = [AIMessage(answer()), AIMessage(invalid), AIMessage(invalid), AIMessage(truth_answer())]
            with self.subTest(invalid=invalid), self.assertRaises(SkillError) as captured:
                await select_skills(model, MESSAGES, self.snapshots)
            self.assertIn(captured.exception.issue, ("selection.json:ambiguous", "selection.json:value", "selection.json:extra_data"))
            self.assertEqual(len(model._calls), 3); self.assertEqual(len(model._responses), 1)

    async def test_false_truth_on_full_snapshot_json_fallback_is_recorded_as_blocked(self):
        model = ScriptModel(); model._unsupported = True
        reviewed = json.loads(truth_answer(truth=False))
        model._responses = [AIMessage(answer()), AIMessage(json.dumps(reviewed))]
        with self.assertRaises(SkillError) as captured:
            await select_skills(model, MESSAGES, self.snapshots)
        details = captured.exception.details
        self.assertEqual(captured.exception.code, "skillsPrerequisite")
        self.assertEqual(details["fallback_reason"], "tool_protocol_unsupported")
        self.assertEqual(details["loaded_skill_ids"], [])
        self.assertEqual(details["model_calls"], 2)
        self.assertEqual(details["prerequisite_review"], {"status": "blocked", "result": reviewed})
        self.assertNotIn("FULL_PRIVATE_BODY_1", model._calls[-1][0].text)

    async def test_true_additional_prerequisite_releases_unchanged_draft(self):
        reviewed = json.loads(truth_answer())
        reviewed["methods"][0]["additional_prerequisites"] = [{"requirement": "同组", "skill_excerpt": "必须是同一组数量的和与差。", "proposition": "原题满足同组前提", "basis": "fact", "arithmetic": None, "truth": True, "evidence": "原图两量同组", "scope": "required", "guard_excerpt": None, "guard_trigger_excerpt": None, "guard_proposition": None, "guard_truth": None, "guard_evidence": None}]
        model = ScriptModel(); model._responses = [read(self.path), decision(), truth_decision(reviewed)]
        raw, details = await select_skills(model, MESSAGES, self.snapshots)
        self.assertEqual(json.loads(raw), json.loads(answer()))
        self.assertEqual(details["prerequisite_review"], {"status": "passed", "result": reviewed})

    async def test_unsupported_final_truth_never_adds_sixth_call(self):
        class Unsupported(Exception):
            status_code = 400
            body = {"error": {"param": "tools", "message": "tools unsupported"}}
        model = ScriptModel(); model._responses = [read(self.path, i) for i in range(3)] + [decision(), Unsupported(), AIMessage(truth_answer())]
        with self.assertRaises(Unsupported): await select_skills(model, MESSAGES, self.snapshots)
        self.assertEqual(len(model._calls), 5); self.assertEqual(len(model._responses), 1)

    async def test_no_selected_method_skips_truth_and_cancellation_propagates(self):
        model = ScriptModel(); model._responses = [decision(json.loads(answer(None))), truth_decision()]
        _, details = await select_skills(model, MESSAGES, self.snapshots)
        self.assertEqual(details["precondition_review"], "not_run_no_selection")
        self.assertEqual(len(model._calls), 1); self.assertEqual(len(model._responses), 1)
        class WaitingTruth(ScriptModel):
            async def _agenerate(self, messages, stop=None, run_manager=None, **kwargs):
                if self._bound == ["PrerequisiteTruth"]:
                    await self._wait.wait()
                return self._generate(messages, stop, run_manager, **kwargs)
        model = WaitingTruth(); model._wait = asyncio.Event(); model._responses = [read(self.path), decision(), truth_decision()]
        task = asyncio.create_task(select_skills(model, MESSAGES, self.snapshots))
        for _ in range(100):
            if model._bound == ["PrerequisiteTruth"]: break
            await asyncio.sleep(0.001)
        self.assertEqual(model._bound, ["PrerequisiteTruth"])
        task.cancel()
        with self.assertRaises(asyncio.CancelledError): await task
        self.assertEqual(len(model._responses), 1)


if __name__ == "__main__": unittest.main()
