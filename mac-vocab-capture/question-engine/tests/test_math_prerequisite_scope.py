"""Branch provenance is checked structurally; mathematical judgment remains model-owned."""
import copy
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import HumanMessage, SystemMessage
from math_skills import SkillError, SnapshotBackend, prerequisite_requirements, prerequisite_schema, select_skills, snapshots_for
from test_math_skills import ScriptModel, declared_policy
from test_math_tool_strategy import decision, read, truth_decision

DIRECT = "直接给出和与差时，两量必须是同一时刻的数量。"
RATIO = "给出倍率关系时，倍率必须已知；使用份数关系求和与差。"
INTEGER = "求物品个数时，结果必须为非负整数。"
BODY = DIRECT + "\n" + RATIO + "\n" + INTEGER


def snapshot(body=BODY, identifier="branch-method"):
    row = {"id": identifier, "version_id": "version-branch", "title": "带条件分支的数量方法", "category": "数量关系", "instructions": body}
    row["teaching_policy"] = declared_policy(row)
    return snapshots_for([row])


def draft(identifier="branch-method"):
    return {"method_id": identifier, "visual_method_ids": [], "reason": "本题数量关系符合候选方法", "applicability": [
        {"method_id": identifier, "status": "applicable", "conditions": [
            {"requirement": "原图数量关系明确", "evidence": "原图提供数量关系", "status": "met"}]}]}


def extra(scope="not_current_branch", truth=None, guard_truth=False, guard_excerpt=RATIO, evidence="原题给和与差，没有倍率分支", excerpt="倍率必须已知"):
    return {"requirement": "倍率必须已知", "skill_excerpt": excerpt, "proposition": "原图给出所需倍率", "basis": "fact", "arithmetic": None, "truth": truth,
        "evidence": "原题没有给倍率", "scope": scope, "guard_excerpt": guard_excerpt,
        "guard_trigger_excerpt": "给出倍率关系时", "guard_proposition": "原题通过倍率关系求和与差", "guard_truth": guard_truth, "guard_evidence": evidence}


def reviewed(identifier="branch-method", branch=DIRECT, extras=None, fixed_truth=True):
    return {"methods": [{"method_id": identifier, "current_branch": {"skill_excerpt": branch, "evidence": "原题明确给出本分支的数量关系"},
        "conditions": [{"condition_id": "p1", "proposition": "原图明确给出本题的数量关系", "basis": "fact", "arithmetic": None, "truth": fixed_truth, "evidence": "独立检查本题固定必要前提"}],
        "additional_prerequisites": extras or [], "coverage_complete": True}]}


class ScopedTruthSchemaTests(unittest.TestCase):
    def setUp(self):
        self.snapshots = snapshot()
        self.schema = prerequisite_schema(prerequisite_requirements(draft()), self.snapshots)

    def test_excluded_branch_preserves_unknown_requirement_and_false_grounded_guard(self):
        value = reviewed(extras=[extra()])
        result = self.schema.model_validate(value).model_dump()
        self.assertEqual(result, value)
        self.assertIsNone(result["methods"][0]["additional_prerequisites"][0]["truth"])
        self.assertFalse(result["methods"][0]["additional_prerequisites"][0]["guard_truth"])

    def test_universal_consequent_cannot_supply_its_own_false_guard(self):
        condition = {"requirement": "结果必须是非负整数", "skill_excerpt": "结果必须为非负整数",
            "proposition": "原题结果为整数", "basis": "fact", "arithmetic": None, "truth": False, "evidence": "计数算式有余数", "scope": "not_current_branch",
            "guard_excerpt": "结果必须为非负整数", "guard_trigger_excerpt": "结果必须为非负整数",
            "guard_proposition": "计数结果必须为非负整数", "guard_truth": False,
            "guard_evidence": "结果不是整数，所以声称不用整数规则"}
        with self.assertRaises((SkillError, ValueError)):
            self.schema.model_validate(reviewed(extras=[condition]))

    def test_current_branch_and_guard_excerpts_must_be_literal_and_coupled(self):
        for change in ({"guard_excerpt": "伪造规则"}, {"guard_excerpt": DIRECT}, {"guard_evidence": " "},
            {"guard_truth": None}, {"guard_truth": True}, {"guard_truth": 0}, {"guard_excerpt": None},
            {"guard_excerpt": ""}, {"guard_evidence": None}, {"guard_truth": "false"},
            {"guard_trigger_excerpt": "倍率必须已知"}, {"guard_trigger_excerpt": None},
            {"guard_trigger_excerpt": " "}, {"guard_trigger_excerpt": "给出倍率关系时，倍率必须已知"},
            {"guard_trigger_excerpt": "伪造触发条件"}, {"guard_proposition": None}, {"guard_proposition": " "},
            {"guard_trigger_excerpt": "大" * 321}, {"guard_proposition": "大" * 161}):
            value = reviewed(extras=[extra()]); value["methods"][0]["additional_prerequisites"][0].update(change)
            with self.subTest(change=change), self.assertRaises((SkillError, ValueError)):
                self.schema.model_validate(value)
        for branch in ("伪造分支", " ", "大" * 601):
            value = reviewed(branch=branch)
            with self.subTest(branch=branch), self.assertRaises((SkillError, ValueError)):
                self.schema.model_validate(value)
        value = reviewed(); value["methods"][0]["current_branch"]["evidence"] = " "
        with self.assertRaises(SkillError): self.schema.model_validate(value)

    def test_unconditional_guards_cannot_manufacture_branch_exclusion(self):
        unguarded = {"requirement": "结果是非负整数", "skill_excerpt": "结果必须为非负整数", "proposition": "原题结果是整数", "basis": "fact", "arithmetic": None, "truth": False,
            "evidence": "原题结果有余数", "scope": "required", "guard_excerpt": None, "guard_trigger_excerpt": None, "guard_proposition": None, "guard_truth": None, "guard_evidence": None}
        value = reviewed(extras=[unguarded])
        self.assertEqual(self.schema.model_validate(value).model_dump(), value)
        for scope in ("not_current_branch",):
            invalid = copy.deepcopy(value); invalid["methods"][0]["additional_prerequisites"][0]["scope"] = scope
            with self.assertRaises(SkillError): self.schema.model_validate(invalid)
        # Honestly unknown scope can be recorded; the application gate blocks it.
        value["methods"][0]["additional_prerequisites"][0]["scope"] = "unknown"
        self.assertEqual(self.schema.model_validate(value).model_dump(), value)

    def test_required_conditional_rule_needs_true_guard_not_completed_check(self):
        for guard_truth in (False, None):
            value = reviewed(extras=[extra(scope="required", truth=True, guard_truth=guard_truth)])
            with self.assertRaises(SkillError): self.schema.model_validate(value)
        value = reviewed(extras=[extra(scope="required", truth=False, guard_truth=True)])
        self.assertEqual(self.schema.model_validate(value).model_dump(), value)


class ScopedTruthGraphTests(unittest.IsolatedAsyncioTestCase):
    async def run_review(self, value, *, body=BODY, original="原图直接给出两量和80、差20", identifier="branch-method"):
        snapshots = snapshot(body, identifier)
        model = ScriptModel(); model._responses = [read(next(iter(SnapshotBackend(snapshots).files))), decision(draft(identifier)), truth_decision(value)]
        self.model = model
        return await select_skills(model, [SystemMessage("选择完整方法"), HumanMessage(original)], snapshots)

    async def test_same_skill_other_branch_unknown_does_not_block_current_branch(self):
        value = reviewed(extras=[extra()])
        raw, details = await self.run_review(value)
        self.assertEqual(json.loads(raw), draft())
        self.assertEqual(details["prerequisite_review"], {"status": "passed", "result": value})
        self.assertEqual(details["model_calls"], 3)
        self.assertIn("原图直接给出两量和80、差20", self.model._calls[-1][1].text)
        self.assertNotIn("本题数量关系符合候选方法", self.model._calls[-1][0].text)

    async def test_same_skill_active_branch_unknown_or_false_still_blocks(self):
        # Paired with the preceding direct-sum/difference case: this original uses the ratio branch.
        for truth in (False, None):
            value = reviewed(branch=RATIO, extras=[extra(scope="required", truth=truth, guard_truth=True,
                evidence="原题说先由倍率求和差，因此倍率分支触发")])
            with self.subTest(truth=truth), self.assertRaises(SkillError) as captured:
                await self.run_review(value, original="原图说先由倍率关系求和与差，但倍率被遮住")
            self.assertEqual(captured.exception.code, "skillsPrerequisite")
            self.assertEqual(captured.exception.details["prerequisite_review"], {"status": "blocked", "result": value})
            self.assertEqual(len(self.model._calls), 3)

    async def test_unknown_scope_blocks_even_when_precondition_and_guard_appear_true(self):
        value = reviewed(extras=[extra(scope="unknown", truth=True, guard_truth=True)])
        with self.assertRaises(SkillError) as captured: await self.run_review(value)
        self.assertEqual(captured.exception.code, "skillsPrerequisite")

    async def test_active_false_fixed_corner_and_ring_integer_prerequisites_are_not_waived(self):
        fixtures = [
            ("corner", "四角等人数路线需要总人数除以8后间隔数为整数。\n其他只求差的分支不使用路线计数。", "四角等人数路线需要总人数除以8后间隔数为整数。", "总人数178，178÷8=22余2", "四角等人数路线，总人数178"),
            ("ring", "空心方阵外圈人数必须为4的倍数。\n其他只求差的分支不使用外圈计数。", "空心方阵外圈人数必须为4的倍数。", "外圈14人，14÷4=3余2", "方阵外圈14人")]
        for identifier, body, branch, fact, original in fixtures:
            value = reviewed(identifier=identifier, branch=branch, fixed_truth=False)
            value["methods"][0]["conditions"][0]["evidence"] = fact
            with self.subTest(identifier=identifier), self.assertRaises(SkillError) as captured:
                await self.run_review(value, body=body, identifier=identifier, original=original)
            self.assertEqual(captured.exception.code, "skillsPrerequisite")
            self.assertIs(captured.exception.details["prerequisite_review"]["result"]["methods"][0]["conditions"][0]["truth"], False)

    async def test_active_false_additional_integer_preconditions_are_not_waived(self):
        for fact in ("178÷8有余数", "14不是4的倍数"):
            condition = {"requirement": "结果是非负整数", "skill_excerpt": "结果必须为非负整数", "proposition": "原题结果是整数", "basis": "fact", "arithmetic": None, "truth": False,
                "evidence": fact, "scope": "required", "guard_excerpt": INTEGER, "guard_trigger_excerpt": "求物品个数时", "guard_proposition": "原题正在求物品个数", "guard_truth": True,
                "guard_evidence": "原题要求物品个数，触发整数规则"}
            value = reviewed(extras=[condition])
            with self.subTest(fact=fact), self.assertRaises(SkillError) as captured:
                await self.run_review(value, original="原题要求物品个数，" + fact)
            self.assertEqual(captured.exception.code, "skillsPrerequisite")
            self.assertEqual(len(self.model._calls), 3)


if __name__ == "__main__": unittest.main()
