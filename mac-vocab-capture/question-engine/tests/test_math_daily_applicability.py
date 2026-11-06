"""Daily protocol checks transport/source binding, not mathematical entailment."""
import copy
import json
import unittest
from pathlib import Path
import sys
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
from math_skills import (SkillError, SnapshotBackend, daily_prerequisite_schema,
    DAILY_REVIEW_REPAIR_GUIDANCE, prerequisite_requirements, select_skills, snapshots_for)
from test_math_skills import MESSAGES, ScriptModel, answer, skills, truth_answer
from test_math_tool_strategy import decision, read, truth_decision
from test_math_selection_roles import declared_roles
import question_engine as engine


def daily_answer(identifier="id-0", visuals=None, **kwargs):
    value = json.loads(truth_answer(identifier, visuals, **kwargs))
    for method in value["methods"]:
        del method["current_branch"]
    return value


def reviewed(value=None):
    return AIMessage(content="", tool_calls=[{"name": "DailyPrerequisiteTruth",
        "args": daily_answer() if value is None else value, "id": "truth", "type": "tool_call"}])


class DailySchemaTests(unittest.TestCase):
    def setUp(self):
        self.snapshots = snapshots_for(skills())
        self.schema = daily_prerequisite_schema(prerequisite_requirements(json.loads(answer())),
            self.snapshots, original_messages=MESSAGES[1:])

    def test_compact_contract_and_exact_coverage(self):
        self.assertEqual(self.schema.model_validate(daily_answer()).model_dump(), daily_answer())
        published = self.schema.model_json_schema()
        self.assertEqual(set(published["$defs"]["DailySourceMethod"]["required"]),
            {"method_id", "conditions", "additional_prerequisites", "coverage_complete"})
        self.assertNotIn("guard_truth", published["$defs"]["DailySourceAdditional"]["properties"])
        for mutation in ("identity", "missing", "duplicate", "extra"):
            value = daily_answer()
            if mutation == "identity": value["methods"][0]["method_id"] = "id-1"
            if mutation == "missing": value["methods"][0]["conditions"] = []
            if mutation == "duplicate": value["methods"][0]["conditions"] *= 2
            if mutation == "extra": value["methods"][0]["conditions"][0]["condition_id"] = "p2"
            with self.assertRaises((SkillError, ValueError)):
                self.schema.model_validate(value)

    def test_source_choices_are_request_local_and_still_validate_exact_quotes(self):
        requirements = prerequisite_requirements(json.loads(answer()))
        image = HumanMessage(content=[{"type": "image_url", "image_url": {"url": "data:image/png;base64,fixture"}}])
        for messages, expected in (([HumanMessage("请判断。"), image], {"skill", "problem_image"}),
                                   ([HumanMessage("原数14，另数1。")], {"skill", "problem_text"}),
                                   ([HumanMessage("原数14，另数1。"), image], {"skill", "problem_text", "problem_image"})):
            schema = daily_prerequisite_schema(requirements, self.snapshots, original_messages=messages)
            choices = schema.model_json_schema()["$defs"]["DailySourceOperand"]["properties"]["origin"]["enum"]
            self.assertEqual(set(choices), expected)

    def test_additional_actual_rule_is_literal_source_bound_and_not_a_branch_tree(self):
        value = daily_answer(); condition = value["methods"][0]["conditions"][0]
        extra = {k: v for k, v in condition.items() if k != "condition_id"}
        extra.update(requirement="本题数量为同一组", skill_excerpt="必须是同一组数量的和与差。")
        value["methods"][0]["additional_prerequisites"] = [extra]
        self.schema.model_validate(value)
        for key, replacement in (("skill_excerpt", "虚构规则"), ("evidence", " "), ("requirement", " ")):
            bad = copy.deepcopy(value); bad["methods"][0]["additional_prerequisites"][0][key] = replacement
            with self.assertRaises(SkillError): self.schema.model_validate(bad)
        bad = copy.deepcopy(value); bad["methods"][0]["additional_prerequisites"][0]["scope"] = "not_current_branch"
        with self.assertRaises(ValueError): self.schema.model_validate(bad)

    def test_computed_truth_is_locally_checked_not_claimed(self):
        value = daily_answer(); condition = value["methods"][0]["conditions"][0]
        condition.update(basis="computed", proposition="两量差为非零整数", arithmetic={
            "operands": [{"name": "q1", "value": "72", "origin": "problem_text", "source_excerpt": "两量和72，差18。"},
                         {"name": "q2", "value": "18", "origin": "problem_text", "source_excerpt": "两量和72，差18。"}],
            "expression": "q1/q2", "predicate": "integer", "comparison_expression": None})
        self.schema.model_validate(value)
        condition["truth"] = False
        with self.assertRaises(SkillError) as captured: self.schema.model_validate(value)
        self.assertTrue(captured.exception.issue.endswith("truth_mismatch"))
        condition["truth"] = True; condition["arithmetic"]["operands"][0]["value"] = "73"
        with self.assertRaises(SkillError) as captured: self.schema.model_validate(value)
        self.assertTrue(captured.exception.issue.endswith("source_value"))

    def test_quote_and_duplicate_diagnostics_preserve_exact_source_rejection(self):
        from math_skills import json_repair_guidance
        value = daily_answer()
        extra = {k: v for k, v in value["methods"][0]["conditions"][0].items() if k != "condition_id"}
        extra.update(requirement="同组数量", skill_excerpt="必须是同一组数量的和与差。")
        value["methods"][0]["additional_prerequisites"] = [extra]
        self.schema.model_validate(value)
        for extras, reason in (([dict(extra, skill_excerpt="改写规则")], "quote_not_in_body"),
                               ([extra, copy.deepcopy(extra)], "duplicate_excerpt")):
            rejected = copy.deepcopy(value)
            rejected["methods"][0]["additional_prerequisites"] = extras
            with self.assertRaises(SkillError) as caught:
                self.schema.model_validate(rejected)
            self.assertTrue(caught.exception.issue.endswith(reason))
            self.assertTrue(json_repair_guidance(caught.exception.issue))
            self.assertNotIn("改写规则", caught.exception.issue)
        self.assertEqual(json_repair_guidance("review.methods[0].conditions[0].arithmetic:unused_operand:SECRET"), "")


class DailyFrameworkTests(unittest.IsolatedAsyncioTestCase):
    async def test_two_read_rounds_leave_independent_review_and_one_repair(self):
        invalid = daily_answer()
        condition = invalid["methods"][0]["conditions"][0]
        extra = {k: v for k, v in condition.items() if k != "condition_id"}
        extra.update(requirement="同一组数量", skill_excerpt="不存在于原方法的改写")
        invalid["methods"][0]["additional_prerequisites"] = [extra]
        value, details, model = await self.run_daily([
            read(self.path(), 0), read(self.path(), 1), decision(), reviewed(invalid), reviewed()])
        self.assertEqual(value, json.loads(answer()))
        self.assertEqual(len(model._calls), 5)
        self.assertEqual(model._bindings[2][0], ["SkillSelection"])
        self.assertIn("读取工具已关闭", model._calls[2][0].text)
        self.assertEqual(details["protocol_repairs"], [
            "review.methods[0].additional_prerequisites[0].skill_excerpt:quote_not_in_body"])
        self.assertEqual(details["prerequisite_review"]["result"], daily_answer())
        with self.assertRaises(SkillError):
            await self.run_daily([
                read(self.path(), 0), read(self.path(), 1), decision(), reviewed(invalid), reviewed(invalid)])

    async def test_two_read_rounds_cannot_give_review_a_second_shared_repair(self):
        invalid_selection = json.loads(answer())
        del invalid_selection["applicability"][0]["conditions"][0]["evidence"]
        invalid_review = daily_answer()
        del invalid_review["methods"][0]["coverage_complete"]
        model = ScriptModel()
        model._responses = [read(self.path(), 0), read(self.path(), 1),
            decision(invalid_selection), decision(), reviewed(invalid_review), reviewed()]
        with self.assertRaises(SkillError):
            await select_skills(model, MESSAGES, snapshots_for(skills()), prerequisite_protocol="daily")
        self.assertEqual(len(model._calls), 5)
        self.assertEqual(len(model._responses), 1)

    async def run_daily(self, responses, rows=None, unsupported=False):
        snapshots = snapshots_for(rows or skills())
        model = ScriptModel(); model._responses = responses; model._unsupported = unsupported
        result = await select_skills(model, MESSAGES, snapshots, prerequisite_protocol="daily")
        return json.loads(result[0]), result[1], model

    def path(self, rows=None):
        return next(iter(SnapshotBackend(snapshots_for(rows or skills())).files))

    async def test_actual_read_only_framework_then_fresh_nonanchored_review_three_calls(self):
        draft = json.loads(answer()); draft["reason"] = "DRAFT_REASON_DO_NOT_ANCHOR"
        draft["applicability"][0]["conditions"][0]["evidence"] = "DRAFT_EVIDENCE_DO_NOT_ANCHOR"
        value, details, model = await self.run_daily([read(self.path()), decision(draft), reviewed()])
        self.assertEqual(value, draft)
        self.assertEqual(details["model_calls"], 3)
        self.assertEqual(details["precondition_review"], "independent_daily_truth")
        self.assertEqual(details["prerequisite_protocol"], "daily")
        self.assertEqual(details["loaded_skill_ids"], ["id-0"])
        self.assertFalse(any("FULL_PRIVATE_BODY" in m.text for m in model._calls[0]))
        self.assertTrue(any(isinstance(m, ToolMessage) and "FULL_PRIVATE_BODY_0" in m.text for m in model._calls[1]))
        review = "\n".join(m.text for m in model._calls[2])
        self.assertIn("FULL_PRIVATE_BODY_0", review)
        self.assertIn(MESSAGES[1].text, review)
        self.assertNotIn("DRAFT_REASON_DO_NOT_ANCHOR", review)
        self.assertNotIn("DRAFT_EVIDENCE_DO_NOT_ANCHOR", review)
        self.assertEqual(model._bindings[-1][0], ["DailyPrerequisiteTruth"])
        self.assertNotIn("write_file", str(model._bindings))

    async def test_false_unknown_incomplete_and_missing_additional_block_without_upgrade(self):
        for truth, coverage, extra in ((False, True, False), (None, True, False), (True, False, False), (True, True, True)):
            value = daily_answer(truth=truth, coverage=coverage)
            if extra:
                value["methods"][0]["additional_prerequisites"] = [{"requirement": "同一组数量", "skill_excerpt": "必须是同一组数量的和与差。",
                    "proposition": "本题给出同一组数量", "basis": "fact", "arithmetic": None, "truth": None, "evidence": "缺少事实"}]
            with self.assertRaises(SkillError) as captured:
                await self.run_daily([read(self.path()), decision(), reviewed(value)])
            self.assertEqual(captured.exception.code, "skillsPrerequisite")
            self.assertEqual(captured.exception.details["prerequisite_review"]["status"], "blocked")

    async def test_null_selection_does_not_invoke_reviewer(self):
        value, details, model = await self.run_daily([read(self.path()), decision(json.loads(answer(None)))])
        self.assertIsNone(value["method_id"])
        self.assertEqual(details["precondition_review"], "not_run_no_selection")
        self.assertEqual(len(model._calls), 2)
        self.assertEqual(details["prerequisite_protocol"], "daily")

    async def test_ordinary_engine_explicitly_routes_daily_without_changing_thinking(self):
        class Pool:
            async def acquire(self, configuration):
                self.configuration = configuration
                return "test-key", object()
            def release(self, key):
                self.released = key
        pool = Pool()
        payload = {"id": "daily-engine", "question": "两量和72，差18。", "instructions": MESSAGES[0].text,
            "context": {"text": "两量和72，差18。"}, "task": "math_method_selection", "teaching_skills": skills(),
            "configuration": {"api": "chatCompletions", "endpoint": "http://127.0.0.1/v1/chat/completions",
                "model": "test-model", "api_key": "test-key", "thinking": "off"}}
        mocked = AsyncMock(return_value=(answer(None), {"prerequisite_protocol": "daily"}))
        events = []
        with patch.object(engine, "select_skills", mocked):
            await engine.stream_answer(payload, events.append, pool=pool)
        self.assertEqual(mocked.await_args.kwargs, {"prerequisite_protocol": "daily"})
        self.assertEqual(pool.configuration["thinking"], "off")
        self.assertEqual(events[0]["type"], "done")

    async def test_daily_and_selection_share_only_one_protocol_repair(self):
        invalid = daily_answer(); invalid["methods"][0]["conditions"][0]["condition_id"] = "p2"
        _, details, model = await self.run_daily([read(self.path()), decision(), reviewed(invalid), reviewed()])
        self.assertEqual(details["protocol_repairs"], ["selection:fields"])
        self.assertEqual(len(model._calls), 4)
        with self.assertRaises(SkillError):
            await self.run_daily([read(self.path()), decision(), reviewed(invalid), reviewed(invalid), reviewed()])

    async def test_arithmetic_repair_requires_full_daily_resubmission_without_defaulting_arrays(self):
        invalid = daily_answer()
        invalid["methods"][0]["conditions"][0].update(basis="computed", arithmetic={
            "operands": [{"name": "q1", "value": "72", "origin": "problem_text", "source_excerpt": "两量和72，差18。"}],
            "expression": "72-18", "predicate": "integer", "comparison_expression": None})
        _, details, model = await self.run_daily([read(self.path()), decision(), reviewed(invalid), reviewed()])
        self.assertEqual(details["model_calls"], 4)
        self.assertEqual(details["protocol_repairs"], ["review.methods[0].conditions[0].arithmetic:literal_operand"])
        feedback = model._calls[-1][-1].text
        self.assertIn(DAILY_REVIEW_REPAIR_GUIDANCE, feedback)
        self.assertNotIn("guard_truth", feedback)
        self.assertNotIn("current_branch", feedback)
        self.assertNotIn("FULL_PRIVATE_BODY", feedback)
        missing = daily_answer()
        del missing["methods"][0]["additional_prerequisites"]
        failed_model = ScriptModel()
        failed_model._responses = [read(self.path()), decision(), reviewed(invalid), reviewed(missing), reviewed()]
        with self.assertRaises(SkillError) as captured:
            await select_skills(failed_model, MESSAGES, snapshots_for(skills()), prerequisite_protocol="daily")
        self.assertEqual(captured.exception.issue, "review.methods[0].additional_prerequisites:missing_field")
        self.assertEqual(len(failed_model._calls), 4)

    async def test_daily_expected_result_is_checked_not_rebound_as_a_source(self):
        value = daily_answer()
        condition = value["methods"][0]["conditions"][0]
        condition.update(basis="computed", proposition="两原题数相差54", arithmetic={
            "operands": [{"name": "q1", "value": "72", "origin": "problem_text", "source_excerpt": "两量和72，差18。"},
                         {"name": "q2", "value": "18", "origin": "problem_text", "source_excerpt": "两量和72，差18。"}],
            "expression": "q1-q2", "predicate": "equal", "comparison_expression": "54"})
        _, details, _ = await self.run_daily([read(self.path()), decision(), reviewed(value)])
        actual = details["prerequisite_review"]["result"]["methods"][0]["conditions"][0]
        self.assertEqual(actual, condition)
        wrong = copy.deepcopy(value)
        wrong["methods"][0]["conditions"][0]["arithmetic"]["comparison_expression"] = "55"
        with self.assertRaises(SkillError) as captured:
            daily_prerequisite_schema(prerequisite_requirements(json.loads(answer())),
                snapshots_for(skills()), original_messages=MESSAGES[1:]).model_validate(wrong)
        self.assertTrue(captured.exception.issue.endswith("truth:truth_mismatch"))

    async def test_unused_operand_repair_preserves_source_and_actual_predicate(self):
        invalid = daily_answer()
        condition = invalid["methods"][0]["conditions"][0]
        condition.update(basis="computed", proposition="原题差数为正", arithmetic={
            "operands": [{"name": "q1", "value": "72", "origin": "problem_text", "source_excerpt": "两量和72，差18。"},
                         {"name": "q2", "value": "18", "origin": "problem_text", "source_excerpt": "两量和72，差18。"}],
            "expression": "q2", "predicate": "greater_than", "comparison_expression": "0"})
        corrected = copy.deepcopy(invalid)
        corrected["methods"][0]["conditions"][0]["arithmetic"]["operands"] = [condition["arithmetic"]["operands"][1]]
        _, details, model = await self.run_daily([read(self.path()), decision(), reviewed(invalid), reviewed(corrected)])
        self.assertEqual(details["protocol_repairs"], ["review.methods[0].conditions[0].arithmetic:unused_operand"])
        self.assertIn("声明了未参与", model._calls[-1][-1].text)
        self.assertIn("每个声明的qN都必须", model._calls[-1][-1].text)
        self.assertIn("不要把自己算出的答案", model._calls[-1][-1].text)
        actual = details["prerequisite_review"]["result"]["methods"][0]["conditions"][0]
        self.assertEqual(actual, corrected["methods"][0]["conditions"][0])
        self.assertEqual(details["model_calls"], 4)

    async def test_image_only_numeric_source_requires_explicit_model_correction(self):
        messages = [MESSAGES[0], HumanMessage(content=[
            {"type": "text", "text": "请按原图用小学算术判断。"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,fixture"}}]),
            HumanMessage("请按原图判断，不用方程。")]
        invalid = daily_answer()
        condition = invalid["methods"][0]["conditions"][0]
        condition.update(basis="computed", proposition="楼层间隔为正整数", arithmetic={
            "operands": [{"name": "q1", "value": "14", "origin": "problem_text", "source_excerpt": "从1楼到14楼"},
                         {"name": "q2", "value": "1", "origin": "problem_text", "source_excerpt": "从1楼到14楼"}],
            "expression": "q1-q2", "predicate": "positive_integer", "comparison_expression": None})
        corrected = copy.deepcopy(invalid)
        for operand in corrected["methods"][0]["conditions"][0]["arithmetic"]["operands"]:
            operand["origin"] = "problem_image"
        model = ScriptModel()
        model._responses = [read(self.path()), decision(), reviewed(invalid), reviewed(corrected)]
        _, details = await select_skills(model, messages, snapshots_for(skills()), prerequisite_protocol="daily")
        self.assertEqual(details["model_calls"], 4)
        self.assertEqual(len(details["protocol_repairs"]), 1)
        self.assertIn('本请求数字可声明的来源恰为：["skill", "problem_image"]', model._calls[2][0].text)
        self.assertTrue(details["protocol_repairs"][0].endswith("origin:field_type"))
        self.assertIn("仅在原图中的数字用problem_image", model._calls[-1][-1].text)
        actual = details["prerequisite_review"]["result"]["methods"][0]["conditions"][0]
        self.assertEqual(actual, corrected["methods"][0]["conditions"][0])
        # No image means the same purported correction is rejected, never rebound locally.
        schema = daily_prerequisite_schema(prerequisite_requirements(json.loads(answer())),
            snapshots_for(skills()), original_messages=[HumanMessage("请判断。")])
        with self.assertRaises(ValueError):
            schema.model_validate(corrected)

    async def test_strict_review_feedback_does_not_receive_daily_guidance(self):
        invalid = json.loads(truth_answer())
        invalid["methods"][0]["conditions"][0]["condition_id"] = "p2"
        model = ScriptModel()
        model._responses = [read(self.path()), decision(), truth_decision(invalid), truth_decision()]
        _, details = await select_skills(model, MESSAGES, snapshots_for(skills()), prerequisite_protocol="strict")
        self.assertEqual(details["precondition_review"], "independent_truth")
        self.assertNotIn(DAILY_REVIEW_REPAIR_GUIDANCE, model._calls[-1][-1].text)

    async def test_unsupported_tools_keep_honest_full_snapshot_and_daily_review(self):
        value, details, model = await self.run_daily([AIMessage(content=answer()), AIMessage(content=json.dumps(daily_answer()))], unsupported=True)
        self.assertEqual(value["method_id"], "id-0")
        self.assertEqual(details["mode"], "full_snapshot_fallback")
        self.assertEqual(details["fallback_reason"], "tool_protocol_unsupported")
        self.assertEqual(details["precondition_review"], "independent_daily_truth")
        self.assertEqual(len(model._calls), 2)

    async def test_daily_does_not_bypass_exact_declared_roles(self):
        rows = skills(2); declared_roles(rows[0], ["solution"]); declared_roles(rows[1], ["visual"])
        paths = list(SnapshotBackend(snapshots_for(rows)).files)
        reads = AIMessage(content="", tool_calls=[read(path, i).tool_calls[0] for i, path in enumerate(paths)])
        value, details, model = await self.run_daily([reads, decision(json.loads(answer("id-1", ["id-0"]))),
            decision(json.loads(answer("id-0", ["id-1"]))), reviewed(daily_answer("id-0", ["id-1"]))], rows=rows)
        self.assertEqual(value["method_id"], "id-0")
        self.assertEqual(details["protocol_repairs"], ["selection.method_id:role"])
        self.assertEqual(len(model._calls), 4)
