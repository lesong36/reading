"""Exact arithmetic consistency checks; predicate relevance remains model-owned."""
import asyncio
import copy
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from math_skills import SkillError, SnapshotBackend, original_problem_sources, prerequisite_requirements, prerequisite_schema, select_skills, snapshots_for
from test_math_skills import ScriptModel, declared_policy
from test_math_tool_strategy import decision, read, truth_decision
from test_math_prerequisite_scope import draft, reviewed

BODY = "人数必须为4的倍数。人数除以4的商必须为非负整数。"


def snapshots():
    row = {"id": "branch-method", "version_id": "v", "title": "整数计数", "category": "计数", "instructions": BODY}
    row["teaching_policy"] = declared_policy(row)
    return snapshots_for([row])


def witness(number="14", origin="problem_text"):
    return {"operands": [{"name": "q1", "value": number, "origin": origin, "source_excerpt": "原题人数" + number},
        {"name": "q2", "value": "4", "origin": "skill", "source_excerpt": "人数必须为4的倍数"}],
        "expression": "q1/q2", "predicate": "nonnegative_integer", "comparison_expression": None}


def review(number="14", truth=False, *, additional=False, origin="problem_text"):
    value = reviewed(branch="人数必须为4的倍数。")
    predicate = {"proposition": "本题人数除以4的商是非负整数", "basis": "computed", "arithmetic": witness(number, origin),
        "truth": truth, "evidence": "按原题人数与完整方法规则常数独立计算"}
    if additional:
        value["methods"][0]["additional_prerequisites"] = [{"requirement": "人数除以4商为非负整数", "skill_excerpt": "人数除以4的商必须为非负整数",
            **predicate, "scope": "required", "guard_excerpt": None, "guard_trigger_excerpt": None,
            "guard_proposition": None, "guard_truth": None, "guard_evidence": None}]
    else:
        value["methods"][0]["conditions"][0].update(predicate)
    return value


class ComputedSchemaTests(unittest.TestCase):
    def schema(self, original=None):
        return prerequisite_schema(prerequisite_requirements(draft()), snapshots(),
            original_messages=original if original is not None else [HumanMessage("原题人数14"), HumanMessage("原题人数16")])

    def test_computed_truth_matches_exact_result_and_preserves_false(self):
        for number, truth in (("14", False), ("16", True)):
            value = review(number, truth)
            self.assertEqual(self.schema().model_validate(value).model_dump(), value)
        for truth in (True, None):
            with self.subTest(truth=truth), self.assertRaises(SkillError) as captured:
                self.schema().model_validate(review("14", truth))
            self.assertEqual(captured.exception.issue, "review.methods[0].conditions[0].truth:truth_mismatch")

    def test_computed_missing_witness_requires_unknown_not_false_or_true(self):
        for truth in (True, False):
            value = review(truth=truth); value["methods"][0]["conditions"][0]["arithmetic"] = None
            with self.assertRaises(SkillError) as captured: self.schema().model_validate(value)
            self.assertEqual(captured.exception.issue, "review.methods[0].conditions[0].arithmetic:witness")
        value = review(truth=None); value["methods"][0]["conditions"][0]["arithmetic"] = None
        self.assertEqual(self.schema([]).model_validate(value).model_dump(), value)

    def test_fact_cannot_carry_computed_witness_and_proposition_cannot_be_blank(self):
        value = review(); value["methods"][0]["conditions"][0]["basis"] = "fact"
        with self.assertRaises(SkillError) as captured: self.schema().model_validate(value)
        self.assertEqual(captured.exception.issue, "review.methods[0].conditions[0].arithmetic:fields")
        value = review(); value["methods"][0]["conditions"][0]["proposition"] = " "
        with self.assertRaises(SkillError) as captured: self.schema().model_validate(value)
        self.assertEqual(captured.exception.issue, "review.methods[0].conditions[0].proposition:empty")

    def test_source_binding_only_uses_original_user_text_and_images(self):
        source = [SystemMessage("原题人数14"), AIMessage("原题人数14")]
        with self.assertRaises(SkillError) as captured: self.schema(source).model_validate(review())
        self.assertEqual(captured.exception.issue, "review.methods[0].conditions[0].arithmetic:problem_source")
        image = {"type": "image_url", "image_url": {"url": "data:image/png;base64,fixture"}}
        self.assertEqual(original_problem_sources([HumanMessage([{"type": "text", "text": "原题人数14"}, image]), AIMessage("不参与绑定")]), (["原题人数14"], True))
        value = review(origin="problem_image")
        self.schema([HumanMessage([image])]).model_validate(value)
        with self.assertRaises(SkillError): self.schema([AIMessage([image])]).model_validate(value)

    def test_wrong_expression_or_invented_sources_get_safe_witness_issue(self):
        for change in ({"expression": "q1//q2"}, {"expression": "__import__('private_secret')"},
            {"expression": "q1/q2+4"}, {"operands": [witness()["operands"][0]]}):
            value = review(); value["methods"][0]["conditions"][0]["arithmetic"].update(change)
            with self.subTest(change=change), self.assertRaises(SkillError) as captured: self.schema().model_validate(value)
            self.assertEqual(captured.exception.issue, "review.methods[0].conditions[0].arithmetic:expression")
            self.assertNotIn("private_secret", captured.exception.issue)
        value = review(); value["methods"][0]["conditions"][0]["arithmetic"]["operands"][0]["source_excerpt"] = "伪造原题人数14"
        with self.assertRaises(SkillError): self.schema().model_validate(value)


class ComputedGraphTests(unittest.IsolatedAsyncioTestCase):
    async def select(self, reviews, original="原题人数14"):
        rows = snapshots(); model = ScriptModel(); model._responses = [read(next(iter(SnapshotBackend(rows).files))), decision(draft()), *reviews]
        self.model = model
        return await select_skills(model, [SystemMessage("选择完整方法"), HumanMessage(original)], rows)

    async def test_false_computed_fixed_and_additional_block_while_true_is_released(self):
        for additional in (False, True):
            value = review(additional=additional)
            with self.assertRaises(SkillError) as captured: await self.select([truth_decision(value)])
            self.assertEqual(captured.exception.code, "skillsPrerequisite")
            self.assertEqual(captured.exception.details["prerequisite_review"], {"status": "blocked", "result": value})
            self.assertEqual(len(self.model._calls), 3)
            value = review("16", True, additional=additional)
            raw, details = await self.select([truth_decision(value)], original="原题人数16")
            self.assertEqual(json.loads(raw), draft())
            self.assertEqual(details["prerequisite_review"]["status"], "passed")

    async def test_computed_unknown_without_sources_preserves_blocked_result_and_never_retries(self):
        for additional in (False, True):
            with self.subTest(additional=additional):
                value = review(truth=None, additional=additional)
                field = "additional_prerequisites" if additional else "conditions"
                value["methods"][0][field][0]["arithmetic"] = None
                with self.assertRaises(SkillError) as captured:
                    await self.select([truth_decision(value), truth_decision(review("16", True))], original="原题人数被遮住")
                self.assertEqual(captured.exception.code, "skillsPrerequisite")
                self.assertEqual(captured.exception.details["prerequisite_review"]["result"], value)
                self.assertEqual(len(self.model._calls), 3)
                self.assertEqual(len(self.model._responses), 1)

    async def test_false_math_claim_is_only_corrected_by_one_new_model_review(self):
        invalid, corrected = review(truth=True), review(truth=False)
        with self.assertRaises(SkillError) as captured:
            await self.select([truth_decision(invalid), truth_decision(corrected)])
        details = captured.exception.details
        self.assertEqual(captured.exception.code, "skillsPrerequisite")
        self.assertEqual(details["protocol_repairs"], ["review.methods[0].conditions[0].truth:truth_mismatch"])
        self.assertEqual(details["prerequisite_review"]["result"], corrected)
        self.assertEqual(details["model_calls"], 4)
        feedback = self.model._calls[-1][-1].text
        self.assertIn("truth:truth_mismatch", feedback)
        self.assertNotIn("14", feedback)

    async def test_safe_specific_source_error_reaches_only_one_model_repair(self):
        invalid, corrected = review(), review()
        invalid["methods"][0]["conditions"][0]["arithmetic"]["operands"][0]["source_excerpt"] = "private_secret原题人数14"
        with self.assertRaises(SkillError) as captured:
            await self.select([truth_decision(invalid), truth_decision(corrected)])
        self.assertEqual(captured.exception.code, "skillsPrerequisite")
        self.assertEqual(captured.exception.details["protocol_repairs"], ["review.methods[0].conditions[0].arithmetic:problem_source"])
        self.assertEqual(captured.exception.details["model_calls"], 4)
        self.assertEqual(captured.exception.details["prerequisite_review"]["result"], corrected)
        feedback = self.model._calls[-1][-1].text
        self.assertIn("arithmetic:problem_source", feedback)
        self.assertNotIn("private_secret", feedback)
        self.assertNotIn("14", feedback)

    async def test_repeated_mismatch_cannot_extend_global_five_call_budget(self):
        rows = snapshots(); path = next(iter(SnapshotBackend(rows).files)); model = ScriptModel()
        model._responses = [read(path, i) for i in range(3)] + [decision(draft()), truth_decision(review(truth=True)), truth_decision(review())]
        with self.assertRaises(SkillError) as captured:
            await select_skills(model, [SystemMessage("选择"), HumanMessage("原题人数14")], rows)
        self.assertEqual(captured.exception.issue, "review.methods[0].conditions[0].truth:truth_mismatch")
        self.assertEqual(len(model._calls), 5); self.assertEqual(len(model._responses), 1)

    async def test_json_compatibility_uses_identical_arithmetic_consistency_rules(self):
        model = ScriptModel(); model._unsupported = True
        model._responses = [AIMessage(json.dumps(draft())), AIMessage(json.dumps(review(truth=True))), AIMessage(json.dumps(review()))]
        with self.assertRaises(SkillError) as captured:
            await select_skills(model, [SystemMessage("选择"), HumanMessage("原题人数14")], snapshots())
        self.assertEqual(captured.exception.code, "skillsPrerequisite")
        self.assertEqual(captured.exception.details["fallback_reason"], "tool_protocol_unsupported")
        self.assertEqual(captured.exception.details["protocol_repairs"], ["review.methods[0].conditions[0].truth:truth_mismatch"])
        self.assertEqual(len(model._calls), 3)


if __name__ == "__main__": unittest.main()
