"""Transport/repair boundaries, not verification of mathematical entailment."""
import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage, ToolMessage
from langchain.agents.middleware.tool_call_limit import ToolCallLimitExceededError
from math_skills import SnapshotBackend, SkillError, select_skills, selection_schema, snapshots_for
from test_math_skills import MESSAGES, ScriptModel, answer, skills, truth_answer, review_metadata


def decision(value=None, **metadata):
    return AIMessage(content="", response_metadata=metadata, tool_calls=[{
        "name": "SkillSelection", "args": json.loads(answer()) if value is None else value,
        "id": "selection", "type": "tool_call"}])


def truth_decision(value=None, **metadata):
    return AIMessage(content="", response_metadata=metadata, tool_calls=[{
        "name": "PrerequisiteTruth", "args": json.loads(truth_answer()) if value is None else value,
        "id": "truth", "type": "tool_call"}])


def read(path, index=0):
    return AIMessage(content="", tool_calls=[{
        "name": "read_file", "args": {"file_path": path}, "id": f"read-{index}", "type": "tool_call"}])


class SelectionSchemaTests(unittest.TestCase):
    def test_request_local_typed_schema_has_strict_nested_four_field_contract(self):
        snapshots = snapshots_for(skills())
        schema = selection_schema(snapshots)
        self.assertEqual(schema.model_validate(json.loads(answer())).model_dump(), json.loads(answer()))
        published = schema.model_json_schema()
        self.assertEqual(set(published["required"]), {"method_id", "visual_method_ids", "reason", "applicability"})
        self.assertFalse(published["additionalProperties"])
        condition = published["$defs"]["SelectionCondition"]
        self.assertEqual(set(condition["required"]), {"requirement", "evidence", "status"})
        self.assertFalse(condition["additionalProperties"])
        self.assertEqual(condition["properties"]["evidence"]["maxLength"], 120)
        other_schema = selection_schema(snapshots_for(skills()[1:]))
        with self.assertRaises(SkillError) as captured:
            other_schema.model_validate(json.loads(answer()))
        self.assertEqual(captured.exception.issue, "selection.method_id:unknown_identity")


class ToolStrategyTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.snapshots = snapshots_for(skills())
        self.path = next(iter(SnapshotBackend(self.snapshots).files))

    async def select(self, responses):
        model = ScriptModel()
        model._responses = responses
        raw, details = await select_skills(model, MESSAGES, self.snapshots)
        return json.loads(raw), details, model

    async def test_final_output_tool_keeps_native_json_and_actual_body_disclosure(self):
        for metadata in ({"finish_reason": "tool_calls"}, {"stop_reason": "tool_use"}, {"status": "completed"}):
            with self.subTest(metadata=metadata):
                value, details, model = await self.select([read(self.path), decision(**metadata), truth_decision()])
                self.assertEqual(value, json.loads(answer()))
                self.assertEqual(details, {"mode": "deepagents_skills", "loaded_skill_ids": ["id-0"],
                    "model_calls": 3, **review_metadata()})
                self.assertEqual(len(model._calls), 3)
                self.assertNotIn("FULL_PRIVATE_BODY", model._calls[0][0].text)
                self.assertTrue(any("FULL_PRIVATE_BODY_0" in message.text
                    for message in model._calls[1] if isinstance(message, ToolMessage)))

    async def test_final_reserved_call_keeps_only_output_schema_tool(self):
        value, details, model = await self.select([read(self.path, i) for i in range(3)] + [decision(), truth_decision()])
        self.assertEqual(value, json.loads(answer()))
        self.assertEqual(len(model._calls), 5)
        self.assertEqual(model._bindings[-1], (["PrerequisiteTruth"], {"tool_choice": "any"}))
        self.assertIn("读取工具已关闭", model._calls[3][0].text)
        self.assertEqual(details["loaded_skill_ids"], ["id-0"])

    async def test_malformed_nested_tool_arguments_repair_once_with_safe_issue(self):
        invalid = json.loads(answer())
        private = "private-question-api-key-body"
        invalid["applicability"][0]["conditions"] = [private]
        value, details, model = await self.select([read(self.path), decision(invalid), decision(), truth_decision()])
        self.assertEqual(value, json.loads(answer()))
        self.assertEqual(details["protocol_repairs"], ["selection.applicability[0].conditions[0]:type"])
        self.assertEqual(len(model._calls), 4)
        self.assertEqual(model._bindings[-1][0], ["PrerequisiteTruth"])
        feedback = model._calls[-2][-1].text
        self.assertIn("不能复制示例编号", feedback)
        self.assertIn("不要为通过校验", feedback)
        self.assertNotIn(private, feedback)
        self.assertNotIn(private, str(details))

    async def test_text_and_output_tool_errors_share_one_repair_allowance(self):
        invalid = json.loads(answer())
        del invalid["applicability"][0]["conditions"][0]["evidence"]
        error_issue = "selection.applicability[0].conditions[0].evidence:fields"
        for first, second in ((decision(invalid), AIMessage(json.dumps(invalid))),
                              (AIMessage(json.dumps(invalid)), decision(invalid))):
            with self.subTest(first=type(first).__name__):
                model = ScriptModel()
                model._responses = [read(self.path), first, second, truth_decision()]
                with self.assertRaises(SkillError) as captured:
                    await select_skills(model, MESSAGES, self.snapshots)
                self.assertEqual(captured.exception.issue, error_issue)
                self.assertEqual(len(model._calls), 3)
                self.assertEqual(len(model._responses), 1)
        for first, second in ((decision(invalid), AIMessage("说明\n" + answer())),
                              (AIMessage(json.dumps(invalid)), decision())):
            value, details, model = await self.select([read(self.path), first, second, truth_decision()])
            self.assertEqual(value, json.loads(answer()))
            self.assertEqual(details["protocol_repairs"], [error_issue])
            self.assertEqual(len(model._calls), 4)

    async def test_structured_repair_cannot_extend_five_call_budget(self):
        invalid = json.loads(answer())
        invalid["applicability"][0]["conditions"] = ["bad"]
        value, details, model = await self.select([read(self.path, i) for i in range(2)] + [decision(invalid), decision(), truth_decision()])
        self.assertEqual(value, json.loads(answer()))
        self.assertEqual(len(model._calls), 5)
        self.assertEqual(len(details["protocol_repairs"]), 1)
        model = ScriptModel()
        model._responses = [read(self.path, i) for i in range(3)] + [decision(invalid), decision(), truth_decision()]
        with self.assertRaises(SkillError):
            await select_skills(model, MESSAGES, self.snapshots)
        self.assertEqual(len(model._calls), 5)
        self.assertEqual(len(model._responses), 1)

    async def test_mixed_read_and_selection_rejected_before_body_execution(self):
        for malformed in (False, True):
            value = json.loads(answer())
            if malformed:
                value["applicability"][0]["conditions"] = ["bad"]
            combined = decision(value)
            combined.tool_calls.insert(0, read(self.path).tool_calls[0])
            model = ScriptModel()
            model._responses = [combined, decision()]
            reads = []
            original = SnapshotBackend.load_for_model
            def track(backend, path):
                reads.append(path)
                return original(backend, path)
            with self.subTest(malformed=malformed), patch.object(SnapshotBackend, "load_for_model", track):
                with self.assertRaises(SkillError) as captured:
                    await select_skills(model, MESSAGES, self.snapshots)
            self.assertEqual(captured.exception.issue, "selection:invalid")
            self.assertEqual(reads, [])
            self.assertEqual(len(model._calls), 1)

    async def test_twelve_reads_remain_available_with_output_tool(self):
        batch = AIMessage(content="", tool_calls=[read(self.path, i).tool_calls[0] for i in range(12)])
        value, details, model = await self.select([batch, decision(), truth_decision()])
        self.assertEqual(value, json.loads(answer()))
        self.assertEqual(details["loaded_skill_ids"], ["id-0"])
        self.assertEqual(len(model._calls), 3)
        model = ScriptModel()
        batch = AIMessage(content="", tool_calls=[read(self.path, i).tool_calls[0] for i in range(13)])
        model._responses = [batch, decision()]
        with self.assertRaises(ToolCallLimitExceededError):
            await select_skills(model, MESSAGES, self.snapshots)
        self.assertEqual(len(model._calls), 1)

    async def test_ignored_reads_trigger_visible_full_snapshot_fallback(self):
        value, details, model = await self.select([decision(), AIMessage(answer()), AIMessage(truth_answer())])
        self.assertEqual(details["mode"], "full_snapshot_fallback")
        self.assertEqual(details["fallback_reason"], "model_did_not_load_skills")
        self.assertEqual(details["loaded_skill_ids"], [])
        self.assertTrue(value["reason"].startswith("本次为全文兼容选择（未按需调用技能）。"))
        self.assertEqual(len(model._calls), 3)
        self.assertEqual(details["precondition_review"], "independent_truth")
        self.assertNotIn("FULL_PRIVATE_BODY_1", model._calls[-1][0].text)

    async def test_repair_cannot_select_unread_identity_or_call_read_tool(self):
        invalid = json.loads(answer())
        invalid["applicability"][0]["conditions"] = ["bad"]
        unread_path = list(SnapshotBackend(self.snapshots).files)[1]
        for repaired in (decision(json.loads(answer("id-1"))), read(unread_path)):
            model = ScriptModel()
            model._responses = [read(self.path), decision(invalid), repaired]
            with self.subTest(repaired=repaired), self.assertRaises(SkillError):
                await select_skills(model, MESSAGES, self.snapshots)
            self.assertEqual(len(model._calls), 3)
            self.assertEqual(model._bindings[-1][0], ["SkillSelection"])

    async def test_duplicate_structured_outputs_use_same_safe_repair(self):
        repeated = decision()
        repeated.tool_calls.append({**repeated.tool_calls[0], "id": "selection-2"})
        value, details, model = await self.select([read(self.path), repeated, decision(), truth_decision()])
        self.assertEqual(value, json.loads(answer()))
        self.assertEqual(details["protocol_repairs"], ["selection.json:ambiguous"])
        self.assertEqual(len(model._calls), 4)

    async def test_truncated_structured_response_requires_counted_new_decision(self):
        for metadata in ({"finish_reason": "length"}, {"status": "incomplete"}):
            value, details, model = await self.select([read(self.path), decision(**metadata), decision(), truth_decision()])
            self.assertEqual(value, json.loads(answer()))
            self.assertEqual(details["protocol_repairs"], ["selection.json:incomplete"])
            self.assertEqual(len(model._calls), 4)
            model = ScriptModel()
            model._responses = [decision(json.loads(answer(None)), **metadata)]
            with self.assertRaises(SkillError) as captured:
                await select_skills(model, MESSAGES, self.snapshots)
            self.assertEqual(captured.exception.code, "skillsTruncated")

    async def test_conflicting_selection_is_only_fixed_by_new_null_decision(self):
        invalid = json.loads(answer())
        invalid["applicability"][0]["status"] = "conflicting"
        invalid["applicability"][0]["conditions"][0]["status"] = "conflicting"
        corrected = copy.deepcopy(invalid)
        corrected["method_id"] = None
        value, details, model = await self.select([read(self.path), decision(invalid), decision(corrected)])
        self.assertIsNone(value["method_id"])
        self.assertEqual(value["applicability"][0]["status"], "conflicting")
        self.assertEqual(details["protocol_repairs"], ["selection.applicability:selected_identity_mismatch"])
        self.assertEqual(len(model._calls), 3)


    async def test_truth_blocks_false_unknown_and_incomplete_coverage_without_draft_context(self):
        draft = json.loads(answer())
        draft["reason"] = "DRAFT_ANCHOR_DO_NOT_COPY"
        draft["applicability"][0]["conditions"][0]["evidence"] = "DRAFT_EVIDENCE_DO_NOT_COPY"
        image_block = {"type": "image_url", "image_url": {"url": "data:image/png;base64,fixture"}}
        original = [type(MESSAGES[0])("SELECTOR_SYSTEM_DO_NOT_COPY"),
            type(MESSAGES[1])(content=[{"type": "text", "text": "原图资料。"}, image_block]),
            AIMessage("ORIGINAL_HISTORY"), type(MESSAGES[1])(content="用户要求核对原图。")]
        for truth, coverage in ((False, True), (None, True), (True, False)):
            model = ScriptModel()
            result = json.loads(truth_answer(selection=draft, truth=truth, coverage=coverage))
            model._responses = [read(self.path), decision(draft), truth_decision(result), truth_decision()]
            with self.subTest(truth=truth, coverage=coverage), self.assertRaises(SkillError) as captured:
                await select_skills(model, original, self.snapshots)
            self.assertEqual(captured.exception.code, "skillsPrerequisite")
            self.assertEqual(captured.exception.details["prerequisite_review"], {"status": "blocked", "result": result})
            self.assertEqual(captured.exception.details["model_calls"], 3)
            self.assertEqual(len(model._responses), 1)
            messages = model._calls[-1]
            self.assertEqual(messages[1:], original[1:])
            self.assertIn("FULL_PRIVATE_BODY_0", messages[0].text)
            self.assertNotIn("FULL_PRIVATE_BODY_1", messages[0].text)
            for private in ("DRAFT_ANCHOR_DO_NOT_COPY", "DRAFT_EVIDENCE_DO_NOT_COPY", "SELECTOR_SYSTEM_DO_NOT_COPY"):
                self.assertNotIn(private, "\n".join(item.text for item in messages))
            self.assertFalse(any(isinstance(item, ToolMessage) for item in messages))

    async def test_truth_protocol_error_uses_shared_repair_without_draft_context(self):
        invalid = json.loads(truth_answer())
        del invalid["methods"][0]["conditions"][0]["evidence"]
        value, details, model = await self.select([read(self.path), decision(), truth_decision(invalid), truth_decision()])
        self.assertEqual(value, json.loads(answer()))
        self.assertEqual(len(model._calls), 4)
        self.assertEqual(details["protocol_repairs"], ["review.methods[0].conditions[0].evidence:missing_field"])
        self.assertEqual(details["precondition_review"], "independent_truth")
        self.assertIn("系统字段校验未通过", model._calls[-1][-1].text)
        self.assertFalse(any(isinstance(item, ToolMessage) for item in model._calls[-1]))
        invalid_draft = json.loads(answer()); del invalid_draft["applicability"][0]["conditions"][0]["evidence"]
        model = ScriptModel()
        model._responses = [read(self.path), decision(invalid_draft), decision(), truth_decision(invalid), truth_decision()]
        with self.assertRaises(SkillError):
            await select_skills(model, MESSAGES, self.snapshots)
        self.assertEqual(len(model._calls), 4)
        self.assertEqual(len(model._responses), 1)

    async def test_truth_rejects_reads_wrong_phase_and_unread_identities(self):
        invalid = json.loads(truth_answer("id-1"))
        for final in (read(self.path), decision(), truth_decision(invalid)):
            model = ScriptModel()
            model._responses = [read(self.path), decision(), final, truth_decision(invalid), truth_decision()]
            with self.subTest(final=type(final).__name__), self.assertRaises(SkillError):
                await select_skills(model, MESSAGES, self.snapshots)
            self.assertLessEqual(len(model._calls), 4)
            self.assertGreaterEqual(len(model._responses), 1)

    async def test_failed_final_truth_never_returns_unreviewed_draft(self):
        invalid = json.loads(truth_answer()); invalid["methods"][0]["conditions"] = ["invalid"]
        model = ScriptModel()
        model._responses = [read(self.path, i) for i in range(3)] + [decision(), truth_decision(invalid), truth_decision()]
        with self.assertRaises(SkillError):
            await select_skills(model, MESSAGES, self.snapshots)
        self.assertEqual(len(model._calls), 5)
        self.assertEqual(len(model._responses), 1)


if __name__ == "__main__":
    unittest.main()
