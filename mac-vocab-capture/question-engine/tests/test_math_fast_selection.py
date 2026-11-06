import hashlib
import argparse
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from evaluate_teaching import attempt, summarize, run
from math_fast_selection import build_cards, select_fast, MAX_CARD_BYTES
from math_skills import SkillError, snapshots_for
from test_evaluate_teaching import CountingModel
from test_math_skills import declared_policy


def custom(identifier="a", roles=("solution",), body="同一组量，不能混用不同单位。", minimum=4):
    row = {"id": identifier, "version_id": "v", "title": "方法", "category": "数学", "instructions": body}
    row["teaching_policy"] = declared_policy(row, minimum=minimum)
    row["selection_role_policy"] = json.dumps({"method_id": identifier, "version_id": "v",
        "instructions_sha256": hashlib.sha256(body.encode()).hexdigest(), "roles": list(roles)})
    return row


def catalog(directory, rows=()):
    profiles = Path(directory) / "profiles.json"
    index = Path(directory) / "index.json"
    profiles.write_text(json.dumps({"schema_version": 1, "approval_policy": "human_review_only", "profiles": []}))
    index.write_text(json.dumps({"schema_version": 1, "skills": []}))
    return profiles, index


class CardTests(unittest.TestCase):
    def test_custom_complete_body_not_truncated_and_requires_bound_roles(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = catalog(directory)
            body = "边界：" + "不能混淆单位；" * 100
            snapshots = snapshots_for([custom(body=body)])
            self.assertEqual(build_cards(snapshots, *paths)["a"]["instructions"], body)
            row = custom(); del row["selection_role_policy"]
            with self.assertRaises(SkillError): build_cards(snapshots_for([row]), *paths)
            with self.assertRaises(SkillError):
                build_cards(snapshots_for([custom(body="规" * (MAX_CARD_BYTES // 3 + 1))]), *paths)

    def test_project_cards_verify_all_hashes_and_preserve_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = catalog(directory)
            source = Path(directory) / "sample.md"; source.write_text("---\nname: \"sample\"\n---\n" + custom()["instructions"])
            sha = hashlib.sha256(source.read_bytes()).hexdigest()
            row = custom(); row["skill_name"] = "sample"
            row["description"] = "同组数量"
            policy = json.loads(row["teaching_policy"])
            policy = {k: v for k, v in policy.items() if k != "source"}
            policy.update(schema_version=1, skill_name="sample", skill_version="2", skill_sha256=sha, grade4_policy="arithmetic_only")
            row["teaching_policy"] = json.dumps(policy)
            profile = {"skill_name": "sample", "skill_version": "2", "skill_sha256": sha,
                "selection_roles": ["solution"], "grade_guidance": {"minimum_grade": 4, "grade4_policy": "arithmetic_only"}, "prerequisites": ["同组"], "applicable_when": ["关系明确"],
                "exclusions": ["不同对象不可相加"], "limitations": ["用户仍需核验"]}
            entry = {"name": "sample", "version": "2", "sha256": sha, "description": row["description"], "path": "sample.md"}
            paths[0].write_text(json.dumps({"schema_version": 1, "approval_policy": "human_review_only", "profiles": [profile]}))
            paths[1].write_text(json.dumps({"schema_version": 1, "skills": [entry]}))
            snapshots = snapshots_for([row])
            card = build_cards(snapshots, *paths)["a"]
            self.assertEqual(card["exclusions"], profile["exclusions"])
            self.assertNotIn("instructions", card)
            for field, value in (("skill_sha256", "0" * 64), ("skill_version", "1"), ("selection_roles", ["visual"]), ("grade_guidance", {"minimum_grade": 6, "grade4_policy": "extension_requires_permission"})):
                changed = {**profile, field: value}
                paths[0].write_text(json.dumps({"schema_version": 1, "approval_policy": "human_review_only", "profiles": [changed]}))
                with self.subTest(field=field), self.assertRaises(SkillError): build_cards(snapshots, *paths)
            paths[0].write_text(json.dumps({"schema_version": 1, "approval_policy": "human_review_only", "profiles": [profile]}))
            forged = {**row, "instructions": "完全不同的适用条件"}
            forged_policy = {**policy, "instructions_sha256": hashlib.sha256(forged["instructions"].encode()).hexdigest()}
            forged["teaching_policy"] = json.dumps(forged_policy)
            forged["selection_role_policy"] = json.dumps({"method_id": "a", "version_id": "v",
                "instructions_sha256": forged_policy["instructions_sha256"], "roles": ["solution"]})
            with self.assertRaises(SkillError): build_cards(snapshots_for([forged]), *paths)
            source.write_text("被更改的资料")
            with self.assertRaises(SkillError): build_cards(snapshots, *paths)


class FastSelectionTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.snapshots = snapshots_for([custom(), custom("v", ("visual",)), custom("r", ("routing",))])
        self.cards = {s["id"]: {"roles": list(s["selection_roles"]), "instructions": s["instructions"]} for s in self.snapshots}
        self.messages = [SystemMessage("OLD read_file SkillSelection applicability"), HumanMessage("原题条件"), HumanMessage("四年级，不用方程")]
        self.case = {"expected_methods": ["a"], "expected_visuals": ["v"]}

    async def test_single_call_replaces_old_protocol_and_does_not_certify(self):
        model = CountingModel(); model._responses = [AIMessage('{"primary":1,"visual":[2],"reason":"同组数量符合条件"}')]
        with patch.object(CountingModel, "ainvoke", wraps=model.ainvoke) as invoke:
            result = await attempt(model, self.messages, self.snapshots, self.case, "fast_selection", 10, fast_cards=self.cards)
            self.assertEqual(invoke.call_count, 1)
            sent = invoke.call_args.args[0]
            self.assertNotIn("OLD", sent[0].content)
            self.assertNotIn("read_file", sent[0].content)
            self.assertEqual(sent[1:], self.messages[1:])
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["metrics"]["model_calls"], 1)
        self.assertTrue(result["score"]["all_labels_match"])
        self.assertNotIn("applicability", result["decision"])
        self.assertFalse(result["execution"]["mathematical_certification"])
        self.assertEqual(len(result["execution"]["selected_versions"]), 2)
        self.assertEqual(summarize([{"fast_selection": result}])["fast_selection"]["total_model_calls"], 1)

    async def test_evaluator_fast_only_writes_one_lane_and_keeps_gold(self):
        with tempfile.TemporaryDirectory() as directory:
            profiles, index = catalog(directory)
            corpus = Path(directory) / "corpus.json"
            corpus.write_text(json.dumps({"cases": [{"id": "example", "kind": "transfer", "split": "held_out",
                "stem": "同一组数量关系", "grade": 4, "user_constraint": "不用方程", "expected_methods": ["a"],
                "expected_visuals": [], "gold_checks": ["原值"]}]}))
            model = CountingModel(); model._responses = [AIMessage('{"primary":1,"visual":[],"reason":"同组数量"}')]
            class Pool:
                async def acquire(self, _): return "key", model
                def release(self, _): pass
                async def close(self): pass
            args = argparse.Namespace(corpus=str(corpus), output=str(Path(directory) / "report.json"),
                cases=None, limit=0, timeout=10, learning_smoke=False, fast_only=True,
                profiles=str(profiles), skill_index=str(index))
            configuration = {"api": "openai", "api_key": "not-real-secret", "endpoint": "https://example.invalid",
                "model": "fixture", "thinking": "off", "direct_connection": False}
            with patch("evaluate_teaching.ModelPool", Pool), contextlib.redirect_stdout(io.StringIO()):
                await run(args, {"configuration": configuration, "instructions": "OLD protocol",
                    "teaching_skills": [custom()]})
            report = json.loads(Path(args.output).read_text())
            self.assertTrue(report["complete"])
            self.assertEqual(set(report["summary"]), {"fast_selection"})
            row = report["cases"][0]
            self.assertEqual(row["order"], ["fast_selection"])
            self.assertNotIn("framework", row)
            self.assertEqual(row["expected_methods"], ["a"])
            self.assertEqual(row["fast_selection"]["metrics"]["model_calls"], 1)
            self.assertFalse(report["human_approval_granted"])
            self.assertFalse(report["answer_accuracy_evaluated"])

    async def test_invalid_json_ids_duplicates_roles_fail_once_without_repair(self):
        invalid = ['{"primary":1,"primary":2,"visual":[],"reason":"x"}',
            '```json\n{"primary":1,"visual":[],"reason":"x"}\n```',
            '{"primary":99,"visual":[],"reason":"x"}', '{"primary":true,"visual":[],"reason":"x"}',
            '{"primary":1,"visual":[2,2],"reason":"x"}', '{"primary":2,"visual":[],"reason":"x"}',
            '{"primary":3,"visual":[],"reason":"x"}', '{"primary":null,"visual":[1],"reason":"x"}',
            '{"primary":1,"visual":[],"reason":"x","applicability":[]}',
            '{"primary":1,"visual":[],"reason":"x"} extra']
        for content in invalid:
            with self.subTest(content=content):
                model = CountingModel(); model._responses = [AIMessage(content), AIMessage('{"primary":1,"visual":[],"reason":"unused"}')]
                result = await attempt(model, self.messages, self.snapshots, self.case, "fast_selection", 10, fast_cards=self.cards)
                self.assertEqual(result["status"], "failed")
                self.assertEqual(result["metrics"]["model_calls"], 1)
                self.assertEqual(len(model._responses), 1)

    async def test_truncated_or_tool_response_rejected(self):
        for response in (AIMessage('{"primary":1,"visual":[],"reason":"x"}', response_metadata={"finish_reason": "length"}),
                         AIMessage('', tool_calls=[{"name": "read_file", "args": {}, "id": "1"}])):
            model = CountingModel(); model._responses = [response]
            result = await attempt(model, self.messages, self.snapshots, self.case, "fast_selection", 10, fast_cards=self.cards)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["metrics"]["model_calls"], 1)

    async def test_grade_filter_before_model_and_gold_unchanged(self):
        snapshots = snapshots_for([custom(minimum=6)])
        model = CountingModel()
        result = await attempt(model, self.messages, snapshots, self.case, "fast_selection", 10, fast_cards={})
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["metrics"]["model_calls"], 0)
        self.assertEqual(result["expected_method_scope_conflicts"], ["a"])
        self.assertFalse(result["score"]["primary_match"])
        self.assertEqual(result["execution"]["mode"], "eligibility_gate")


if __name__ == "__main__": unittest.main()
