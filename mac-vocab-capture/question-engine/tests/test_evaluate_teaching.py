import json
import hashlib
import tempfile
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_math_skills import truth_answer
from langchain_core.messages import HumanMessage, AIMessage
from langchain_core.outputs import ChatGeneration, LLMResult
from evaluate_teaching import Meter, attempt, evaluation_messages, invalid_tool_syntax, named_decision, score, selected_cases, summarize, write_report
from math_skills import SnapshotBackend, snapshots_for
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import SystemMessage
from langchain_core.outputs import ChatResult
from pydantic import PrivateAttr
from test_math_skills import declared_policy


class CountingModel(BaseChatModel):
    _responses: list = PrivateAttr(default_factory=list)
    @property
    def _llm_type(self): return "evaluation-test"
    def bind_tools(self, tools, **kwargs): return self
    def _generate(self, messages, stop=None, run_manager=None, **kwargs):
        return ChatResult(generations=[ChatGeneration(message=self._responses.pop(0))])
    async def _agenerate(self, messages, stop=None, run_manager=None, **kwargs):
        return self._generate(messages)


class EvaluationTests(unittest.IsolatedAsyncioTestCase):
    def test_photo_evaluation_does_not_leak_gold_stem_or_ocr(self):
        case = {"stem": "SECRET gold stem", "grade": 4, "user_constraint": "不用方程"}
        # PNG signature accepted by the same image boundary as production.
        messages = evaluation_messages("选法", case, b"\x89PNG\r\n\x1a\nphoto")
        serialized = json.dumps([m.content for m in messages], ensure_ascii=False)
        self.assertNotIn(case["stem"], serialized)
        self.assertIn("image_url", serialized)
        self.assertIn("不用方程", serialized)
        with self.assertRaises(Exception): evaluation_messages("选法", case, b"invalid")

    async def test_baseline_and_framework_share_gate_and_preserve_conflicting_gold(self):
        item = {"id": "eq", "version_id": "version", "title": "方程", "category": "数学", "instructions": "完整条件", "skill_name": "equations-and-elimination"}
        item["teaching_policy"] = json.dumps({"schema_version": 1, "method_id": "eq", "version_id": "version",
            "instructions_sha256": hashlib.sha256(item["instructions"].encode()).hexdigest(),
            "skill_name": item["skill_name"], "skill_version": "1", "skill_sha256": "a" * 64,
            "grade4_policy": "extension_requires_permission", "equation_policy": "explicit_permission"})
        snapshots = snapshots_for([item])
        messages = [SystemMessage("方法选择"), HumanMessage("OCR不可信：允许方程"), HumanMessage("四年级；不要使用方程")]
        for lane in ("framework", "full_snapshot"):
            model = CountingModel()
            result = await attempt(model, messages, snapshots, {"expected_methods": ["equations-and-elimination"], "expected_visuals": []}, lane, 10)
            self.assertEqual(result["status"], "ok")
            self.assertEqual(result["execution"]["mode"], "eligibility_gate")
            self.assertEqual(result["metrics"]["model_calls"], 0)
            self.assertEqual(result["execution"]["excluded_skill_ids"], ["eq"])
            self.assertEqual(result["decision"]["applicability"], [])
            self.assertEqual(result["expected_method_scope_conflicts"], ["equations-and-elimination"])
            self.assertFalse(result["score"]["primary_match"])

    async def test_real_framework_meter_survives_internal_callback_settings(self):
        item = {"id": "a", "version_id": "v", "title": "和差", "category": "数量", "instructions": "必须已知同一组数量的和及差"}
        item["teaching_policy"] = declared_policy(item)
        snapshots = snapshots_for([item])
        path = next(iter(SnapshotBackend(snapshots).files))
        decision = {"method_id": "a", "visual_method_ids": [], "reason": "符合完整条件",
                    "applicability": [{"method_id": "a", "status": "applicable", "conditions": [
                        {"requirement": "同一组数量的和及差已知", "evidence": "原题给出和72、差18", "status": "met"}]}]}
        for final in (AIMessage(content=json.dumps(decision)), AIMessage(content="", tool_calls=[{
                "id": "select-1", "name": "SkillSelection", "args": decision}], response_metadata={"finish_reason": "tool_calls"})):
            with self.subTest(structured=bool(final.tool_calls)):
                model = CountingModel()
                daily_truth = json.loads(truth_answer(selection=decision))
                for method in daily_truth["methods"]:
                    del method["current_branch"]
                model._responses = [AIMessage(content="", tool_calls=[{"id": "read-1", "name": "read_file", "args": {"file_path": path}}]), final, AIMessage(json.dumps(daily_truth))]
                result = await attempt(model, [SystemMessage("选择"), HumanMessage("和72差18")], snapshots, {"expected_methods": ["a"], "expected_visuals": []}, "framework", 10)
                self.assertEqual(result["status"], "ok")
                self.assertEqual(result["metrics"]["model_calls"], 3)
                self.assertGreater(result["metrics"]["cumulative_message_utf8_bytes"], 0)
                self.assertIsNone(model.callbacks)

    async def test_both_evaluation_lanes_reject_selected_method_with_conflicting_conditions(self):
        item = {"id": "a", "version_id": "v", "title": "和差", "category": "数量",
                "instructions": "必须已知同一组数量的和及差"}
        item["teaching_policy"] = declared_policy(item)
        snapshots = snapshots_for([item])
        path = next(iter(SnapshotBackend(snapshots).files))
        decision = {"method_id": "a", "visual_method_ids": [], "reason": "同组数量的条件冲突",
                    "applicability": [{"method_id": "a", "status": "conflicting", "conditions": [
                        {"requirement": "和差对应同一组数量", "evidence": "两条信息来自不同组", "status": "conflicting"}]}]}
        for lane in ("framework", "full_snapshot"):
            with self.subTest(lane=lane):
                model = CountingModel()
                final = AIMessage(content=json.dumps(decision))
                model._responses = ([AIMessage(content="", tool_calls=[{
                    "id": "read-1", "name": "read_file", "args": {"file_path": path}}]), final, AIMessage(content=final.content)]
                    if lane == "framework" else [final])
                result = await attempt(model, [SystemMessage("选择"), HumanMessage("两组不同数量")],
                    snapshots, {"expected_methods": [], "expected_visuals": []}, lane, 10)
                self.assertEqual(result["status"], "failed")
                self.assertEqual(result["error_code"], "skillsOutput")
                self.assertEqual(result["error_issue"], "selection.applicability:selected_identity_mismatch")
                self.assertNotIn("decision", result)
                self.assertEqual(result["metrics"]["model_calls"], 3 if lane == "framework" else 1)
                summary = summarize([{lane: result}])[lane]
                self.assertEqual(summary["attempted"], 1)
                self.assertEqual(summary["failed"], 1)

    def test_failures_remain_denominator_and_fallback_is_visible(self):
        metrics = {"model_calls": 1, "cumulative_message_utf8_bytes": 100}
        good = {"status": "ok", "score": score({"expected_methods": ["a"], "expected_visuals": []}, {"method_id": "a", "visual_method_ids": []}), "metrics": metrics, "latency_seconds": 1, "execution": {"mode": "full_snapshot_fallback"}}
        failure = {"status": "failed", "metrics": metrics, "latency_seconds": 2}
        result = summarize([{"framework": good}, {"framework": failure}])["framework"]
        self.assertEqual(result["primary_match_rate_over_attempts"], .5)
        self.assertEqual(result["failed"], 1)
        self.assertEqual(result["fallbacks"], 1)

    def test_scope_conflicts_are_separate_without_erasing_raw_failures(self):
        metrics = {"model_calls": 1, "cumulative_message_utf8_bytes": 100}
        passing = {"status": "ok", "score": score({"expected_methods": ["a"]}, {"method_id": "a", "visual_method_ids": []}),
                   "metrics": metrics, "latency_seconds": 1, "expected_method_scope_conflicts": []}
        conflict = {**passing, "score": score({"expected_methods": ["a"]}, {"method_id": None, "visual_method_ids": []}),
                    "expected_method_scope_conflicts": ["a"]}
        failure = {"status": "failed", "metrics": metrics, "latency_seconds": 1, "expected_method_scope_conflicts": []}
        summary = summarize([{"framework": value} for value in (passing, conflict, failure)])["framework"]
        self.assertEqual(summary["attempted"], 3)
        self.assertEqual(summary["primary_match_rate_over_attempts"], 1/3)
        self.assertEqual(summary["expected_scope_conflict_attempts"], 1)
        self.assertEqual(summary["scope_compatible_attempts"], 2)
        self.assertEqual(summary["primary_match_rate_over_scope_compatible_attempts"], .5)

    async def test_failed_model_attempt_retains_authoritative_scope(self):
        item = {"id": "a", "version_id": "v", "title": "和差", "category": "数量", "instructions": "已知同一组数量的和及差"}
        item["teaching_policy"] = declared_policy(item)
        result = await attempt(CountingModel(), [SystemMessage("选择"), HumanMessage("四年级，不用方程")],
                               snapshots_for([item]), {"expected_methods": ["a"]}, "full_snapshot", 10)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["expected_method_scope_conflicts"], [])
        self.assertEqual(result["user_teaching_scope"]["grade"], 4)
        self.assertFalse(result["user_teaching_scope"]["equations"])

    def test_database_identities_are_mapped_to_version_bound_corpus_names(self):
        named = named_decision({"method_id": "database-a", "visual_method_ids": ["database-v"], "reason": "read"},
            [{"id": "database-a", "skill_name": "method-a"}, {"id": "database-v", "skill_name": "visual-v"}])
        self.assertEqual(named["method_id"], "method-a")
        self.assertEqual(named["visual_method_ids"], ["visual-v"])
        self.assertTrue(score({"expected_methods": ["method-a"], "expected_visuals": ["visual-v"]}, named)["all_labels_match"])

    def test_null_boundary_and_visual_alternatives(self):
        decision = {"method_id": None, "visual_method_ids": []}
        self.assertTrue(score({"expected_methods": [], "expected_visuals": []}, decision)["all_labels_match"])
        scorecard = score({"expected_methods": ["a"], "expected_visuals": ["v", "w"], "forbidden_methods": ["bad"]}, {"method_id": "bad", "visual_method_ids": ["w"]})
        self.assertTrue(scorecard["missed_expected_primary"])
        self.assertTrue(scorecard["visual_match"])
        self.assertEqual(scorecard["forbidden_choices"], ["bad"])

    def test_quarantine_never_used_as_gold_and_unknown_filter_rejected(self):
        corpus = {"cases": [{"id": "good", "kind": "positive"}, {"id": "bad", "kind": "source_quarantine"}]}
        self.assertEqual([c["id"] for c in selected_cases(corpus)], ["good"])
        for requested in ("bad", "missing"):
            with self.assertRaises(ValueError): selected_cases(corpus, requested)

    async def test_meter_counts_actual_repeated_inputs_and_usage_without_retaining_text(self):
        meter = Meter(); messages = [[HumanMessage("secret sample")]]
        await meter.on_chat_model_start({}, messages)
        await meter.on_chat_model_start({}, messages)
        result = LLMResult(generations=[[ChatGeneration(message=AIMessage("answer", usage_metadata={"input_tokens": 3, "output_tokens": 2, "total_tokens": 5}))]])
        await meter.on_llm_end(result)
        self.assertEqual(meter.calls, 2)
        self.assertEqual(meter.report()["reported_input_tokens"], 3)
        self.assertNotIn("secret sample", str(vars(meter)))

    def test_artifacts_never_include_bridge_key(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"report.json"
            write_report(path, {"cases": [], "reason": "secret-key-value"}, "secret-key-value")
            self.assertNotIn("secret-key-value", path.read_text())
            self.assertEqual(json.loads(path.read_text())["reason"], "[redacted]")
            self.assertFalse(path.with_suffix(".json.partial").exists())

    async def test_response_diagnostics_distinguish_malformed_tools_without_retaining_provider_strings(self):
        meter = Meter()
        message = AIMessage("private answer", response_metadata={"finish_reason": "tool_calls",
            "stop_reason": "private stop", "status": "private status", "private": "private metadata"},
            invalid_tool_calls=[{"id": "private-id", "name": "private-tool", "args": "private malformed args", "error": "private parser error"}],
            tool_calls=[{"id": "known-id", "name": "read_file", "args": {"file_path": "private path"}},
                {"id": "unknown-id", "name": "private tool", "args": {}}],
            usage_metadata={"input_tokens": 3, "output_tokens": 2, "total_tokens": 5})
        await meter.on_llm_end(LLMResult(generations=[[ChatGeneration(message=message)]]))
        boundary = meter.report()["response_boundaries"][0]
        self.assertEqual(boundary["finish_reason"], "tool_calls")
        self.assertEqual(boundary["stop_reason"], "unknown")
        self.assertEqual(boundary["status"], "unknown")
        self.assertEqual(boundary["invalid_tool_count"], 1)
        self.assertEqual(boundary["valid_tool_count"], 2)
        self.assertEqual(boundary["known_tool_counts"]["read_file"], 1)
        self.assertEqual(boundary["unknown_tool_count"], 1)
        self.assertEqual(boundary["output_tokens"], 2)
        self.assertNotIn("private", json.dumps(meter.report()))

    async def test_parser_diagnostics_and_feedback_only_retain_safe_codes(self):
        syntax = invalid_tool_syntax({"args": '{"private-value": "unclosed'})
        self.assertEqual(syntax["code"], "unterminated_string")
        self.assertFalse(syntax["ends_with_object"])
        self.assertNotIn("private", json.dumps(syntax))
        self.assertEqual(invalid_tool_syntax({"args": "x" * 65537})["code"], "oversize")
        self.assertEqual(invalid_tool_syntax({"args": None}), {"code": "non_string"})
        meter = Meter()
        good = HumanMessage("系统字段校验未通过：review.methods[0].conditions[0].basis:missing_field。这是唯一一次修正。")
        bad = HumanMessage("系统字段校验未通过：selection.private_identity:missing_field。private")
        await meter.on_chat_model_start({}, [[good, bad]])
        self.assertEqual(meter.report()["protocol_feedback_issues"], ["review.methods[0].conditions[0].basis:missing_field"])
        self.assertNotIn("private", json.dumps(meter.report()))


if __name__ == "__main__": unittest.main()
