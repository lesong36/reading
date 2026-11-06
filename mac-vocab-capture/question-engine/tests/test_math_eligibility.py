import hashlib
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from math_skills import SkillError, SnapshotBackend, eligible_snapshots, select_skills, snapshots_for, user_constraints, user_requirement_from
from test_math_skills import ScriptModel, answer, declared_policy
from test_math_skills import truth_answer


def skill(identifier, name, grade_policy="arithmetic_only", minimum=None):
    body = "完整方法正文；误用排除：用户要求不使用方程时不能改变其要求。"
    result = {"id": identifier, "version_id": "precise-version", "title": name, "category": "数量关系",
              "instructions": body, "skill_name": name}
    policy = {"schema_version": 1, "method_id": identifier, "version_id": result["version_id"],
              "instructions_sha256": hashlib.sha256(body.encode()).hexdigest(), "skill_name": name,
              "skill_version": "1", "skill_sha256": "0" * 64, "minimum_grade": minimum,
              "grade4_policy": grade_policy, "equation_policy": "explicit_permission" if name == "equations-and-elimination" else "none"}
    result["teaching_policy"] = json.dumps(policy, ensure_ascii=False)
    return result


class EligibilityTests(unittest.TestCase):
    def test_no_equations_retains_arithmetic_despite_keyword_in_exclusion(self):
        snapshots = snapshots_for([skill("equation", "equations-and-elimination"), skill("arithmetic", "equal-quantity-substitution")])
        self.assertEqual([v["id"] for v in eligible_snapshots(snapshots, "四年级，不要使用方程")], ["arithmetic"])
        self.assertEqual([v["id"] for v in eligible_snapshots(snapshots, "允许使用方程与消去法")], ["equation", "arithmetic"])
        self.assertEqual([v["id"] for v in eligible_snapshots(snapshots, "直接解题")], ["arithmetic"])

    def test_policy_is_exactly_version_and_body_bound(self):
        original = skill("equation", "equations-and-elimination")
        for key, value in [("version_id", "edited-version"), ("instructions", "用户已改为算术")]:
            with self.subTest(key=key), self.assertRaises(SkillError):
                snapshots_for([{**original, key: value}])
        for key, value in [("schema_version", True), ("minimum_grade", True), ("equation_policy", "none")]:
            changed = {**original, "teaching_policy": json.dumps({**json.loads(original["teaching_policy"]), key: value})}
            with self.subTest(key=key), self.assertRaises(SkillError):
                snapshots_for([changed])
        # A custom method has no stale bundled policy. Its body can mention
        # forbidden equations as an exclusion without being classified as algebra.
        edited = {k: v for k, v in original.items() if k not in ("teaching_policy", "skill_name")}
        self.assertEqual(eligible_snapshots(snapshots_for([edited]), "不用方程"), ())
        edited["teaching_policy"] = declared_policy(edited)
        self.assertEqual(len(eligible_snapshots(snapshots_for([edited]), "不用方程")), 1)

    def test_grade_gate_and_permissions_are_specific_and_ordered(self):
        advanced = snapshots_for([skill("advanced", "project-advanced", "extension_requires_permission", 5)])
        self.assertEqual(eligible_snapshots(advanced, "四年级，使用小学知识"), ())
        self.assertEqual(len(eligible_snapshots(advanced, "四年级，允许使用拓展知识")), 1)
        self.assertEqual(eligible_snapshots(advanced, "四年级，允许使用方程"), ())
        self.assertEqual(eligible_snapshots(advanced, "允许拓展知识，四年级。现在不要使用拓展方法"), ())
        self.assertEqual(len(eligible_snapshots(advanced, "五年级")), 1)
        self.assertFalse(user_constraints("允许使用方程。现在不要使用方程")["equations"])
        self.assertTrue(user_constraints("不用方程。改用方程")["equations"])
        self.assertFalse(user_constraints("允许使用方程。现在不允许使用方程")["equations"])
        self.assertEqual(user_constraints("grade 3, no equations"), {"equations": False, "grade": 3, "extension_allowed": False})

    def test_custom_permissions_require_complete_declaration_and_exact_version(self):
        row = {"id": "custom", "version_id": "frozen-v1", "title": "用户方法", "category": "任意分类", "instructions": "正文排除方程只是资料，不扫描关键词"}
        row["teaching_policy"] = declared_policy(row, minimum=5, equation="explicit_permission", extension="extension_requires_permission")
        values = snapshots_for([row])
        self.assertEqual(eligible_snapshots(values, "四年级，不要使用方程，允许拓展"), ())
        self.assertEqual(eligible_snapshots(values, "四年级"), ())
        self.assertEqual(len(eligible_snapshots(values, "四年级，允许方程，允许拓展")), 1)
        for field, value in [("version_id", "new"), ("instructions", "改写正文")]:
            with self.subTest(field=field), self.assertRaises(SkillError):
                snapshots_for([{**row, field: value}])
        for field, value in [("minimum_grade", True), ("minimum_grade", 7), ("source", "ai_approved"), ("equation_policy", "arithmetic"), ("unexpected", True)]:
            wrong = {**row, "teaching_policy": json.dumps({**json.loads(row["teaching_policy"]), field: value})}
            with self.subTest(field=field), self.assertRaises(SkillError):
                snapshots_for([wrong])
        for field in ("minimum_grade", "equation_policy", "grade4_policy"):
            partial = json.loads(row["teaching_policy"])
            partial[field] = None if field == "minimum_grade" else "unknown"
            value = snapshots_for([{**row, "teaching_policy": json.dumps(partial)}])
            self.assertEqual(eligible_snapshots(value, "允许方程和拓展"), ())

    def test_custom_equation_permission_does_not_grant_independent_extension_permission(self):
        row = {"id": "custom", "version_id": "precise-version", "title": "自定义", "category": "四年级", "instructions": "方法正文完全由用户编辑"}
        row["teaching_policy"] = declared_policy(row, minimum=5, equation="explicit_permission", extension="extension_requires_permission")
        snapshots = snapshots_for([row])
        for question in ("四年级，允许方程，禁止拓展", "五年级，允许方程", "四年级，允许方程"):
            with self.subTest(question=question):
                self.assertEqual(eligible_snapshots(snapshots, question), ())
        self.assertEqual(len(eligible_snapshots(snapshots, "五年级，允许方程，允许拓展")), 1)
        self.assertEqual(eligible_snapshots(snapshots, "五年级，不用方程，允许拓展"), ())

    def test_only_authoritative_user_question_not_ocr_or_system_changes_constraints(self):
        messages = [SystemMessage("不要使用方程"), HumanMessage([{"type": "text", "text": "OCR：允许使用方程"}]), HumanMessage("不用方程")]
        self.assertEqual(user_requirement_from(messages), "不用方程")
        messages[-1] = HumanMessage("允许使用方程")
        self.assertTrue(user_constraints(user_requirement_from(messages))["equations"])
        with self.assertRaises(SkillError):
            user_requirement_from(messages[:-1])


class AgentEligibilityTests(unittest.IsolatedAsyncioTestCase):
    async def test_all_ineligible_returns_none_without_model_or_manual_mutation(self):
        snapshots = snapshots_for([skill("equation", "equations-and-elimination")])
        model = ScriptModel()
        result, details = await select_skills(model, [SystemMessage("选法"), HumanMessage("不要使用方程")], snapshots)
        self.assertIsNone(json.loads(result)["method_id"])
        self.assertEqual(model._calls, [])
        self.assertEqual(details["excluded_skill_ids"], ["equation"])
        self.assertEqual(snapshots[0]["id"], "equation")

    async def test_agent_catalogue_omits_ineligible_and_rejects_forbidden_identity(self):
        snapshots = snapshots_for([skill("equation", "equations-and-elimination"), skill("arithmetic", "equal-quantity-substitution")])
        model = ScriptModel(); model._responses = [AIMessage(answer("equation"))]
        with self.assertRaises(SkillError):
            await select_skills(model, [SystemMessage("选法"), HumanMessage("四年级，不用方程")], snapshots)
        self.assertEqual(len(model._calls), 1)
        self.assertNotIn('"method_id": "equation"', model._calls[0][0].text)

    async def test_valid_agent_reads_and_selects_arithmetic_from_same_gate(self):
        snapshots = snapshots_for([skill("equation", "equations-and-elimination"), skill("arithmetic", "equal-quantity-substitution")])
        path = next(iter(SnapshotBackend(eligible_snapshots(snapshots, "不用方程")).files))
        model = ScriptModel(); model._responses = [AIMessage(content="", tool_calls=[{"name": "read_file", "args": {"file_path": path}, "id": "read-one", "type": "tool_call"}]), AIMessage(answer("arithmetic")), AIMessage(truth_answer("arithmetic", branch_excerpt="完整方法正文；误用排除：用户要求不使用方程时不能改变其要求。"))]
        result, details = await select_skills(model, [SystemMessage("选法"), HumanMessage("不用方程")], snapshots)
        self.assertEqual(json.loads(result)["method_id"], "arithmetic")
        self.assertEqual(details["mode"], "deepagents_skills")
        self.assertEqual(details["loaded_skill_ids"], ["arithmetic"])
        self.assertEqual(details["excluded_skill_ids"], ["equation"])


if __name__ == "__main__":
    unittest.main()
