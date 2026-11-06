"""Automatic selection consistency gate; these declarations do not prove math truth."""
import copy
import json
import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage
from math_skills import SnapshotBackend, APPLICABILITY_PROMPT, SkillError, complete_selection, select_skills, selection_from, snapshots_for
from test_math_skills import truth_answer, MESSAGES, ScriptModel, answer, skills


class ApplicabilityParsingTests(unittest.TestCase):
    def setUp(self):
        self.snapshots = snapshots_for(skills())
        self.value = json.loads(answer("id-0", ["id-1"]))

    def parse(self, value):
        return selection_from(json.dumps(value, ensure_ascii=False), self.snapshots, require_applicability=True)

    def test_valid_primary_visual_and_visual_only(self):
        self.assertEqual(self.parse(self.value), self.value)
        value = json.loads(answer(None, ["id-1"]))
        self.assertEqual(self.parse(value), value)

    def test_null_for_nonmath_and_rejected_candidate_preserves_evidence(self):
        self.assertIsNone(self.parse(json.loads(answer(None)))["method_id"])
        for status, condition in [("missing", "missing"), ("conflicting", "conflicting"), ("not_applicable", "not_met")]:
            value = json.loads(answer(None))
            value["applicability"] = [{"method_id": "id-0", "status": status, "conditions": [
                {"requirement": "同一组数量的和与差", "evidence": "题面没有同一组的差", "status": condition}]}]
            self.assertEqual(self.parse(value)["applicability"], value["applicability"])

    def test_selected_missing_conflicting_or_excluded_cannot_reach_solver(self):
        for status in ("missing", "conflicting", "not_applicable"):
            value = copy.deepcopy(self.value)
            value["applicability"][0]["status"] = status
            value["applicability"][0]["conditions"][0]["status"] = "not_met" if status == "not_applicable" else status
            with self.subTest(status=status), self.assertRaises(SkillError):
                self.parse(value)

    def test_missing_and_contradictory_identity_evidence_are_rejected(self):
        variants = []
        for assessments in (None, [], self.value["applicability"][:1]):
            value = copy.deepcopy(self.value)
            if assessments is None:
                del value["applicability"]
            else:
                value["applicability"] = assessments
            variants.append(value)
        value = copy.deepcopy(self.value); value["method_id"] = None; variants.append(value)
        for status in ("missing", "conflicting", "not_met"):
            value = copy.deepcopy(self.value); value["applicability"][0]["conditions"][0]["status"] = status; variants.append(value)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(SkillError):
                self.parse(value)

    def test_unknown_ids_status_fields_duplicates_empty_and_limits_rejected(self):
        variants = []
        for change in ({"method_id": "invented"}, {"status": "maybe"}, {"answer": 45}, {"conditions": []}, {"conditions": "met"}):
            value = copy.deepcopy(self.value); value["applicability"][0].update(change); variants.append(value)
        for change in ({"status": "unknown"}, {"requirement": " "}, {"evidence": ""}, {"evidence": "题" * 121}, {"evidence": True}, {"answer": 45}):
            value = copy.deepcopy(self.value); value["applicability"][0]["conditions"][0].update(change); variants.append(value)
        value = copy.deepcopy(self.value); value["applicability"].append(copy.deepcopy(value["applicability"][0])); variants.append(value)
        value = copy.deepcopy(self.value); value["applicability"][0]["conditions"] *= 9; variants.append(value)
        value = copy.deepcopy(self.value); value["applicability"] *= 4; variants.append(value)
        value = copy.deepcopy(self.value); value["reason"] = "题" * 3000; variants.append(value)
        value = copy.deepcopy(self.value); value["extra"] = True; variants.append(value)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(SkillError):
                self.parse(value)

    def test_new_payload_budget_is_bounded_separately_from_legacy_records(self):
        value = copy.deepcopy(self.value); value["reason"] = "a" * 4100
        raw = json.dumps(value)
        self.assertGreater(len(raw.encode()), 4000)
        self.assertLess(len(raw.encode()), 8000)
        self.assertEqual(self.parse(value)["reason"], "a" * 200)
        with self.assertRaises(SkillError):
            selection_from(raw, self.snapshots)

    def test_rejection_status_requires_corresponding_unmet_condition(self):
        for status in ("missing", "conflicting", "not_applicable"):
            value = json.loads(answer(None))
            assessment = copy.deepcopy(self.value["applicability"][0]); assessment["status"] = status
            value["applicability"] = [assessment]
            with self.subTest(status=status), self.assertRaises(SkillError):
                self.parse(value)

    def test_structural_diagnostics_identify_fixed_field_rules_without_raw_values(self):
        private = "https://private.example/key=secret-api-key-question-text"
        variants = []
        value = copy.deepcopy(self.value); del value["applicability"]; variants.append((value, "selection:fields"))
        value = copy.deepcopy(self.value); value["method_id"] = private; variants.append((value, "selection.method_id:unknown_identity"))
        value = copy.deepcopy(self.value); value["applicability"][0]["status"] = private; variants.append((value, "selection.applicability[0].status:enum"))
        value = copy.deepcopy(self.value); value["applicability"][0]["conditions"][0]["status"] = private; variants.append((value, "selection.applicability[0].conditions[0].status:enum"))
        value = copy.deepcopy(self.value); value["applicability"][0]["conditions"][0]["evidence"] = private * 3; variants.append((value, "selection.applicability[0].conditions[0].evidence:limit"))
        value = copy.deepcopy(self.value); value["method_id"] = None; variants.append((value, "selection.applicability:selected_identity_mismatch"))
        for value, issue in variants:
            with self.subTest(issue=issue), self.assertRaises(SkillError) as captured:
                self.parse(value)
            self.assertEqual(captured.exception.code, "skillsOutput")
            self.assertEqual(captured.exception.issue, issue)
            self.assertNotIn(private, str(vars(captured.exception)))
            self.assertNotIn(private, str(captured.exception))
        truncated = AIMessage(answer(), response_metadata={"finish_reason": "length"})
        with self.assertRaises(SkillError) as captured:
            complete_selection(truncated, self.snapshots)
        self.assertEqual(captured.exception.issue, "selection.json:incomplete")

    def test_issue_constructor_rejects_unapproved_metadata(self):
        for issue in ("secret-api-key", "selection.api_key:invalid", "selection.reason:secret-api-key",
                      "selection.applicability[999].status:enum", "selection:fields\nsecret"):
            self.assertIsNone(SkillError("skillsOutput", issue=issue).issue)
        self.assertEqual(SkillError("skillsOutput", issue="selection:fields").issue, "selection:fields")
        self.assertIsNone(SkillError("learningInvalid").issue)

    def test_legacy_only_parser_or_explicit_legacy_message(self):
        legacy = {"method_id": "id-0", "visual_method_ids": [], "reason": "旧记录"}
        raw = json.dumps(legacy)
        self.assertEqual(selection_from(raw, self.snapshots), legacy)
        self.assertEqual(complete_selection(AIMessage(raw), self.snapshots, require_applicability=False), legacy)
        with self.assertRaises(SkillError):
            complete_selection(AIMessage(raw), self.snapshots)
        with self.assertRaises(SkillError):
            self.parse(legacy)


class ApplicabilityExecutionTests(unittest.IsolatedAsyncioTestCase):
    async def test_new_requests_and_fallback_reject_legacy_with_bounded_repair(self):
        legacy = json.dumps({"method_id": "id-0", "visual_method_ids": [], "reason": "旧协议"})
        for unsupported in (False, True):
            model = ScriptModel(); model._unsupported = unsupported
            model._responses = [AIMessage(legacy) for _ in range(2 if unsupported else 1)]
            with self.subTest(unsupported=unsupported), self.assertRaises(SkillError):
                await select_skills(model, MESSAGES, snapshots_for(skills()))
            self.assertEqual(len(model._calls), 2 if unsupported else 1)
            self.assertIn(APPLICABILITY_PROMPT, model._calls[0][0].text)
            if unsupported:
                self.assertIn("系统字段校验未通过", model._calls[1][-1].text)

    async def test_loaded_main_and_visual_declarations_reach_the_same_bounded_agent(self):
        snapshots = snapshots_for(skills()); backend = SnapshotBackend(snapshots)
        calls = [{"id": "read-" + str(i), "name": "read_file", "args": {"file_path": path}, "type": "tool_call"}
                 for i, path in enumerate(backend.files)]
        model = ScriptModel(); model._responses = [AIMessage(content="", tool_calls=calls), AIMessage(answer("id-0", ["id-1"])), AIMessage(truth_answer("id-0", ["id-1"]))]
        raw, details = await select_skills(model, MESSAGES, snapshots)
        self.assertEqual(json.loads(raw)["visual_method_ids"], ["id-1"])
        self.assertEqual(details["loaded_skill_ids"], ["id-0", "id-1"])
        self.assertEqual(details["mode"], "deepagents_skills")
        self.assertEqual(len(model._calls), 3)

    async def test_unread_diagnostic_evidence_uses_visible_full_snapshot_fallback(self):
        value = json.loads(answer(None))
        value["applicability"] = [{"method_id": "id-0", "status": "missing", "conditions": [
            {"requirement": "同一组的差", "evidence": "题面缺少差值", "status": "missing"}]}]
        model = ScriptModel(); model._responses = [AIMessage(json.dumps(value)), AIMessage(json.dumps(value))]
        raw, details = await select_skills(model, MESSAGES, snapshots_for(skills()))
        self.assertIsNone(json.loads(raw)["method_id"])
        self.assertEqual(details["mode"], "full_snapshot_fallback")
        self.assertEqual(details["fallback_reason"], "model_did_not_load_skills")
        self.assertEqual(details["loaded_skill_ids"], [])
        self.assertEqual(len(model._calls), 2)

    async def test_loaded_but_conflicting_selected_identity_errors_without_fallback(self):
        snapshots = snapshots_for(skills()); path = next(iter(SnapshotBackend(snapshots).files))
        value = json.loads(answer()); value["applicability"][0]["status"] = "conflicting"
        value["applicability"][0]["conditions"][0]["status"] = "conflicting"
        model = ScriptModel(); model._responses = [AIMessage(content="", tool_calls=[
            {"id": "read-1", "name": "read_file", "args": {"file_path": path}, "type": "tool_call"}]), AIMessage(json.dumps(value)), AIMessage(json.dumps(value))]
        with self.assertRaises(SkillError):
            await select_skills(model, MESSAGES, snapshots)
        self.assertEqual(len(model._calls), 3)

    async def test_field_failure_repaired_once_through_counted_model_node(self):
        snapshots = snapshots_for(skills()); path = next(iter(SnapshotBackend(snapshots).files))
        invalid = json.loads(answer()); del invalid["applicability"][0]["conditions"][0]["evidence"]
        model = ScriptModel(); model._responses = [AIMessage(content="", tool_calls=[
            {"id": "read-1", "name": "read_file", "args": {"file_path": path}, "type": "tool_call"}]),
            AIMessage(json.dumps(invalid)), AIMessage(answer()), AIMessage(truth_answer())]
        raw, details = await select_skills(model, MESSAGES, snapshots)
        self.assertEqual(json.loads(raw)["method_id"], "id-0")
        self.assertEqual(details["mode"], "deepagents_skills")
        self.assertEqual(details["protocol_repairs"], ["selection.applicability[0].conditions[0].evidence:fields"])
        self.assertEqual(len(model._calls), 4)
        self.assertIn("selection.applicability[0].conditions[0].evidence:fields", model._calls[-2][-1].text)
        self.assertEqual(details["loaded_skill_ids"], ["id-0"])

    async def test_repair_cannot_invent_unread_method_or_locally_fill_evidence(self):
        snapshots = snapshots_for(skills()); path = next(iter(SnapshotBackend(snapshots).files))
        invalid = json.loads(answer()); del invalid["applicability"][0]["conditions"][0]["evidence"]
        unread_path = list(SnapshotBackend(snapshots).files)[1]
        for final in (AIMessage(json.dumps(invalid)), AIMessage(answer("id-1")), AIMessage(content="", tool_calls=[
            {"id": "unread", "name": "read_file", "args": {"file_path": unread_path}, "type": "tool_call"}])):
            model = ScriptModel(); model._responses = [AIMessage(content="", tool_calls=[
                {"id": "read-1", "name": "read_file", "args": {"file_path": path}, "type": "tool_call"}]),
                AIMessage(json.dumps(invalid)), final]
            with self.subTest(final=final), self.assertRaises(SkillError):
                await select_skills(model, MESSAGES, snapshots)
            self.assertEqual(len(model._calls), 3)

    async def test_protocol_repair_uses_last_available_call_but_never_sixth(self):
        snapshots = snapshots_for(skills()); path = next(iter(SnapshotBackend(snapshots).files))
        invalid = json.loads(answer()); del invalid["applicability"][0]["conditions"][0]["evidence"]
        reads = [AIMessage(content="", tool_calls=[
            {"id": "read-" + str(i), "name": "read_file", "args": {"file_path": path}, "type": "tool_call"}]) for i in range(4)]
        for read_count in (2, 3):
            model = ScriptModel(); model._responses = reads[:read_count] + [AIMessage(json.dumps(invalid)), AIMessage(answer())]
            if read_count == 2:
                model._responses.append(AIMessage(truth_answer()))
                raw, details = await select_skills(model, MESSAGES, snapshots)
                self.assertEqual(json.loads(raw)["method_id"], "id-0")
                self.assertEqual(len(details["protocol_repairs"]), 1)
            else:
                with self.assertRaises(SkillError):
                    await select_skills(model, MESSAGES, snapshots)
            self.assertEqual(len(model._calls), 5)

    async def test_conflicting_choice_can_only_be_repaired_by_new_valid_decision(self):
        snapshots = snapshots_for(skills()); path = next(iter(SnapshotBackend(snapshots).files))
        invalid = json.loads(answer()); invalid["applicability"][0]["status"] = "conflicting"
        invalid["applicability"][0]["conditions"][0]["status"] = "conflicting"
        correct = copy.deepcopy(invalid); correct["method_id"] = None
        model = ScriptModel(); model._responses = [AIMessage(content="", tool_calls=[
            {"id": "read-1", "name": "read_file", "args": {"file_path": path}, "type": "tool_call"}]),
            AIMessage(json.dumps(invalid)), AIMessage(json.dumps(correct))]
        raw, details = await select_skills(model, MESSAGES, snapshots)
        self.assertIsNone(json.loads(raw)["method_id"])
        self.assertEqual(json.loads(raw)["applicability"][0]["status"], "conflicting")
        self.assertEqual(details["protocol_repairs"], ["selection.applicability:selected_identity_mismatch"])
        self.assertIn("不要为通过校验", model._calls[-1][-1].text)

    async def test_no_eligible_method_emits_current_shape_without_provider(self):
        rows = skills()
        for row in rows:
            policy = json.loads(row["teaching_policy"]); policy["minimum_grade"] = 6; row["teaching_policy"] = json.dumps(policy)
        model = ScriptModel()
        raw, details = await select_skills(model, MESSAGES, snapshots_for(rows))
        self.assertEqual(json.loads(raw)["applicability"], [])
        self.assertEqual(model._calls, [])
        self.assertEqual(details["mode"], "eligibility_gate")
        selection_from(raw, snapshots_for(rows), require_applicability=True)
