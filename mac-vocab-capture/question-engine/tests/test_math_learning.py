import json
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage, HumanMessage
from math_learning import learn_skills, DIMENSIONS, proposal_for
from math_skills import SkillError


class Model:
    def __init__(self, outputs=()):
        self.outputs = list(outputs)
        self.calls = 0
        self.prompts = []
        self.inputs = []

    async def ainvoke(self, messages, config=None):
        self.calls += 1
        self.prompts.append(messages[0].text)
        self.inputs.append(json.loads(messages[-1].text))
        if not self.outputs:
            raise AssertionError("Resuming human review must not invoke model")
        content = self.outputs.pop(0)
        return AIMessage(content=json.dumps(content, ensure_ascii=False) if isinstance(content, dict) else content)


def coverage(kind="uncovered", ids=None):
    return {"coverage": kind, "covered_method_ids": ["known"] if kind == "covered" else [],
            "reason": "Compare exact relationships and original conditions", "pattern_key": "shared-gap-invariant",
            "pattern_evidence_ids": ids if ids is not None else ["q-a", "q-b", "q-c"]}


def evidence(verified=True):
    return [{"question_id": "q-" + name, "text": source, "answer": "independent checked arithmetic",
             "verification": "confirmed" if verified else "unverified", "role": role}
            for name, source, role in (("a", "one original positive", "positive"),
                                       ("b", "second original positive", "positive"),
                                       ("c", "third original positive", "positive"),
                                       ("d", "explicit excluded boundary", "excluded"))]


def proposal():
    return {"title": "Shared invariant method", "category": "Grade four arithmetic",
            "instructions": "Identify the unchanged quantity. Compare the changes using arithmetic. Check all source conditions independently. Exclude problems with missing conditions. Never substitute example numbers for the current question.",
            "trigger": "Same invariant across two operations", "prerequisites": ["Arithmetic"],
            "exclusions": ["Unknown rate or incomplete conditions"], "diagram_templates": ["table"],
            "evidence_ids": ["q-a", "q-b", "q-c", "q-d"], "review_notes": "Human must confirm each step and applicability"}


def review(passed=True):
    return {"checks": [{"dimension": key, "passed": passed, "reason": "Independent evidence remains subject to human verification"}
                       for key in sorted(DIMENSIONS)], "recommendation": "ready_for_human" if passed else "needs_revision"}


class LearningTests(unittest.IsolatedAsyncioTestCase):
    async def run_graph(self, model, learning):
        output, execution = await learn_skills(model, [HumanMessage("Original question")], [{"id": "known"}], learning)
        return json.loads(output), execution

    async def test_known_coverage_never_creates_candidate(self):
        model = Model([coverage("covered", ["q-a"])])
        result, execution = await self.run_graph(model, {"evidence": evidence()})
        self.assertEqual(result["status"], "covered")
        self.assertIsNone(result["proposal"])
        self.assertEqual(execution["model_calls"], 1)

    async def test_unrelated_questions_do_not_count_as_repeated_pattern(self):
        model = Model([coverage(ids=["q-a"])])
        result, _ = await self.run_graph(model, {"evidence": evidence()})
        self.assertEqual(result["status"], "observing")
        self.assertIsNone(result["proposal"])
        self.assertEqual(model.calls, 1)

    async def test_complete_relationship_family_can_draft_across_forward_and_inverse_forms(self):
        # Scripted coverage proves graph/prompt contracts, not an LLM's classification accuracy.
        items = evidence()
        for item, source in zip(items, (
            "每盒装6支，4盒共多少支？共24支，每盒6支，需要多少盒？",
            "每袋装8颗，5袋一共多少颗？",
            "每束7枝，共42枝，可以扎多少束？",
            "每盒数量不同，只知道共有4盒，无法确定总数。",
        )):
            item.update(text=source, grade=4, user_constraint="只用小学算术")
        matched = coverage()
        matched.update(pattern_key="equal-groups-relationship",
                       reason="总数=每组数×组数；q-a两问分别正求总数和逆求组数，q-b正求总数，q-c逆求组数；全部条件与小题均映射到该关系，无额外规律或前置推理。")
        model = Model([matched, proposal(), review()])
        paused, execution = await self.run_graph(model, {"evidence": items})
        self.assertEqual(paused["status"], "awaiting_human")
        self.assertTrue(execution["human_interrupt"])
        self.assertEqual(model.calls, 3)
        prompt = model.prompts[0]
        for criterion in ("同一封闭数量关系族", "正向求值或逆向求未知量", "每个小题", "独立推理阶段",
                          "reason须说明共同关系", "不同数字排列规律", "间接条件推总量"):
            self.assertIn(criterion, prompt)
        self.assertNotIn("仅换数值/名字且完整条件和步骤结构不变", prompt)
        # No human decision was supplied, so the broadened family policy cannot approve.
        self.assertNotEqual(paused["status"], "approved")

    async def test_shared_decoding_procedure_does_not_require_identical_subquestion_bundle(self):
        # Scripted classification checks orchestration and the policy contract,
        # not whether a real model can read a chart or discover this family.
        items = evidence()
        for item, source in zip(items, (
            "读两系列分类图的图例与刻度，问一个读数、单系列最少及两系列差最大。",
            "读单系列分类图的类别与刻度，求最高最低并排序。",
            "读两系列分类图的图例与刻度，核对同类数量大小和倍数判断。",
            "从多年的图形估计未发生年份的总量趋势，需要额外预测假设。",
        )):
            item.update(text=source, grade=4)
        matched = coverage()
        matched.update(pattern_key="categorical-representation-decoding",
                       reason="前三题均先按类别、系列和刻度还原数据，再按各自所问做基本比较；第四题另需预测，不归入。")
        model = Model([matched, proposal(), review()])
        paused, execution = await self.run_graph(model, {"evidence": items})
        self.assertEqual(paused["status"], "awaiting_human")
        self.assertTrue(execution["human_interrupt"])
        self.assertEqual(model.calls, 3)
        self.assertEqual(set(paused["pattern_evidence_ids"]), {"q-a", "q-b", "q-c"})
        for criterion in ("数量关系族还是过程技能族", "相同的语义解码与核对步骤",
                          "不要求各题的小问集合或运算顺序完全相同", "每个小题的去向",
                          "不能用泛泛的读题/计算/验算", "特殊标度"):
            self.assertIn(criterion, model.prompts[0])

    async def test_similar_visuals_with_different_decoding_rules_do_not_supply_draft_threshold(self):
        items = evidence()
        for item, source in zip(items, (
            "普通等距数轴的并列分类图。",
            "刻度断轴，需要先解释省略的轴区间。",
            "叠加累计条，需要从累计位置还原各部分。",
        )):
            item["text"] = source
        model = Model([coverage(ids=["q-a"])])
        result, _ = await self.run_graph(model, {"evidence": items})
        self.assertEqual(result["status"], "observing")
        self.assertIsNone(result["proposal"])
        self.assertEqual(model.calls, 1)

    async def test_extra_reasoning_stage_and_different_digit_laws_still_observe(self):
        # Classification is intentionally supplied by the fixture; non-cited sources
        # must not count toward the repeated-source gate, regardless of text similarity.
        families = (
            ("先从间接条件求两数和，再用和差求两数。", "已知两数和与差，求两数。", "已知和与差直接填两个数。"),
            ("探索重复数字乘积的排列规律。", "探索末位为九的平方规律。", "探索连续整数乘积的规律。"),
        )
        for sources in families:
            with self.subTest(current=sources[0]):
                items = evidence()
                for item, source in zip(items, sources):
                    item["text"] = source
                model = Model([coverage(ids=["q-a"])])
                result, _ = await self.run_graph(model, {"evidence": items})
                self.assertEqual(result["status"], "observing")
                self.assertIsNone(result["proposal"])
                self.assertEqual(model.calls, 1)

    async def test_empty_ocr_can_inspect_current_photo_but_not_fake_repetition(self):
        items = evidence()
        for item in items: item["text"] = ""
        model = Model([coverage("uncertain", [])])
        result, _ = await self.run_graph(model, {"evidence": items})
        self.assertEqual(result["coverage"], "uncertain")
        self.assertIsNone(result["proposal"])

    async def test_draft_pauses_and_fresh_graph_resumes_without_model_calls(self):
        model = Model([coverage(), proposal(), review()])
        paused, execution = await self.run_graph(model, {"evidence": evidence()})
        self.assertEqual(paused["status"], "awaiting_human")
        self.assertTrue(execution["human_interrupt"])
        frozen = json.loads(json.dumps(paused["workflow_state"]))
        fresh = Model()
        result, _ = await self.run_graph(fresh, {"workflow_state": frozen,
            "decision": {"action": "approve", "reviewer": "user", "note": "Checked conditions, steps and counterexample"}})
        self.assertEqual(result["status"], "approved")
        self.assertEqual(fresh.calls, 0)

    async def test_ai_reference_match_and_answer_only_cannot_approve(self):
        items = evidence(False)
        for item in items: item["verification"] = "referenceMatched"
        paused, _ = await self.run_graph(Model([coverage(), proposal(), review()]), {"evidence": items})
        with self.assertRaisesRegex(SkillError, "learningEvidence"):
            await self.run_graph(Model(), {"workflow_state": paused["workflow_state"],
                "decision": {"action": "approve", "reviewer": "user", "note": "AI said matching"}})
        rejected, _ = await self.run_graph(Model(), {"workflow_state": paused["workflow_state"],
            "decision": {"action": "reject", "reviewer": "user", "note": "Evidence insufficient"}})
        self.assertEqual(rejected["status"], "rejected")

    async def test_failed_pedagogical_dimension_cannot_publish(self):
        paused, _ = await self.run_graph(Model([coverage(), proposal(), review(False)]), {"evidence": evidence()})
        with self.assertRaisesRegex(SkillError, "learningEvidence"):
            await self.run_graph(Model(), {"workflow_state": paused["workflow_state"],
                "decision": {"action": "approve", "reviewer": "user", "note": "Try anyway"}})

    async def test_unknown_evidence_and_numeric_pattern_are_repaired_once(self):
        bad = coverage(ids=["fabricated"])
        model = Model([bad, coverage("uncertain", [])])
        result, _ = await self.run_graph(model, {"evidence": evidence()})
        self.assertEqual(model.calls, 2)
        self.assertEqual(result["coverage"], "uncertain")
        bad = coverage(); bad["pattern_key"] = "age-30-years"
        with self.assertRaises(SkillError):
            await self.run_graph(Model([bad, bad]), {"evidence": evidence()})

    async def test_duplicate_original_text_does_not_trigger_draft(self):
        items = evidence()
        for item in items[:3]: item["text"] = "same photographed question"
        result, _ = await self.run_graph(Model([coverage()]), {"evidence": items})
        self.assertIsNone(result["proposal"])

    async def test_whitespace_changes_and_unmatched_current_do_not_fake_repetition(self):
        items = evidence()
        for item, source in zip(items, ["same question", " same\nquestion ", "samequestion"]):
            item["text"] = source
        result, _ = await self.run_graph(Model([coverage()]), {"evidence": items})
        self.assertIsNone(result["proposal"])
        result, _ = await self.run_graph(Model([coverage(ids=["q-b", "q-c", "q-d"])]), {"evidence": evidence()})
        self.assertIsNone(result["proposal"])

    async def test_draft_cannot_cite_an_unrelated_positive(self):
        items = evidence() + [{"question_id": "unrelated", "text": "different structure", "role": "positive"}]
        bad = proposal(); bad["evidence_ids"] = ["q-a", "q-b", "unrelated"]
        with self.assertRaises(SkillError):
            await self.run_graph(Model([coverage(), bad, bad]), {"evidence": items})

    async def test_same_source_cannot_be_both_positive_and_excluded_boundary(self):
        items = evidence(); items[3]["text"] = items[0]["text"] + "\n "
        paused, _ = await self.run_graph(Model([coverage(), proposal(), review()]), {"evidence": items})
        with self.assertRaisesRegex(SkillError, "learningEvidence"):
            await self.run_graph(Model(), {"workflow_state": paused["workflow_state"],
                "decision": {"action": "approve", "reviewer": "user", "note": "Same example with two roles"}})

    async def test_human_edited_candidate_is_reviewed_without_redrafting_then_resumed(self):
        draft = proposal(); draft["instructions"] += " User-edited explicit boundary."
        items = [item for item in evidence() if item["question_id"] != "q-c"]
        draft["evidence_ids"] = [item["question_id"] for item in items]
        model = Model([review()])
        paused, _ = await self.run_graph(model, {"evidence": items,
            "candidate": {"pattern_key": "shared-gap-invariant", "proposal": draft}})
        self.assertEqual(model.calls, 1)
        self.assertEqual(paused["proposal"], draft)
        result, _ = await self.run_graph(Model(), {"workflow_state": paused["workflow_state"],
            "decision": {"action": "approve", "reviewer": "user", "note": "All boundaries and steps checked"}})
        self.assertEqual(result["status"], "approved")

    async def test_frozen_prose_whitespace_survives_review_checkpoint_and_human_resume(self):
        draft = proposal()
        for key in ("title", "category", "instructions", "trigger", "review_notes"):
            draft[key] = "  " + draft[key] + "\n"
        for key in ("prerequisites", "exclusions"):
            draft[key] = ["\t" + value + "  \n" for value in draft[key]]
        model = Model([review()])
        paused, _ = await self.run_graph(model, {"evidence": evidence(),
            "candidate": {"pattern_key": "shared-gap-invariant", "proposal": draft}})
        self.assertEqual(model.calls, 1)
        self.assertEqual(paused["proposal"], draft)
        self.assertEqual(paused["workflow_state"]["state"]["proposal"], draft)
        self.assertEqual(model.inputs[0]["proposal"], draft, "Review the exact current frozen proposal")
        resumed, _ = await self.run_graph(Model(), {"workflow_state": paused["workflow_state"],
            "decision": {"action": "approve", "reviewer": "user", "note": "Checked exact frozen draft"}})
        self.assertEqual(resumed["status"], "approved")
        self.assertEqual(resumed["proposal"], draft)
        self.assertEqual(resumed["workflow_state"]["state"]["proposal"], draft)

    def test_preserved_prose_still_rejects_empty_oversized_and_duplicate_content(self):
        for key in ("title", "category", "instructions", "trigger", "review_notes", "prerequisites", "exclusions"):
            for invalid in (" \t\n", "x" * (12001 if key == "instructions" else 2001)):
                with self.subTest(key=key, invalid_length=len(invalid)):
                    draft = proposal()
                    draft[key] = [invalid] if key in {"prerequisites", "exclusions"} else invalid
                    with self.assertRaises(SkillError):
                        proposal_for(draft, evidence())
        draft = proposal(); draft["instructions"] = " " * 100 + "Too short" + "\n"
        with self.assertRaises(SkillError):
            proposal_for(draft, evidence())
        draft = proposal(); draft["prerequisites"] = ["Arithmetic", " Arithmetic\n"]
        with self.assertRaises(SkillError):
            proposal_for(draft, evidence())
        draft = proposal(); draft["diagram_templates"] = ["invalid-template"]
        with self.assertRaises(SkillError):
            proposal_for(draft, evidence())
        draft = proposal(); draft["diagram_templates"] = [" table "]
        draft["evidence_ids"] = [" q-a ", "q-b", "q-c", "q-d"]
        validated = proposal_for(draft, evidence())
        self.assertEqual(validated["diagram_templates"], ["table"])
        self.assertEqual(validated["evidence_ids"], ["q-a", "q-b", "q-c", "q-d"])

    async def test_grade_and_user_constraints_survive_human_checkpoint(self):
        items = evidence()
        items[0].update(grade=4, user_constraint="不要使用方程，核对全部原题条件")
        paused, _ = await self.run_graph(Model([coverage(), proposal(), review()]), {"evidence": items})
        stored = paused["workflow_state"]["state"]["evidence"][0]
        self.assertEqual(stored["grade"],4)
        self.assertEqual(stored["user_constraint"],items[0]["user_constraint"])
        items[0]["grade"]=True
        with self.assertRaises(SkillError):
            await self.run_graph(Model(), {"evidence":items})

    async def test_failed_model_output_identifies_stage_and_safe_issue(self):
        bad = coverage(); bad["pattern_key"] = "age-30-secret"
        model = Model([bad, bad])
        with self.assertRaises(SkillError) as caught:
            await self.run_graph(model, {"evidence": evidence()})
        self.assertEqual(caught.exception.code, "learningOutput")
        self.assertEqual(caught.exception.stage, "coverage")
        self.assertEqual(caught.exception.issue, "pattern_key")
        self.assertEqual(caught.exception.model_calls, 2)
        self.assertIn("pattern_key", model.prompts[1])
        self.assertNotIn("age-30-secret", model.prompts[1])

    async def test_draft_and_review_failures_keep_global_repair_budget(self):
        bad = proposal(); del bad["exclusions"]
        model = Model([coverage(), bad, bad])
        with self.assertRaises(SkillError) as caught:
            await self.run_graph(model, {"evidence": evidence()})
        self.assertEqual((caught.exception.stage, caught.exception.issue, caught.exception.model_calls),
                         ("draft", "fields", 3))
        bad_review = review(); bad_review["checks"][1] = dict(bad_review["checks"][0])
        model = Model([coverage(), proposal(), bad_review, bad_review])
        with self.assertRaises(SkillError) as caught:
            await self.run_graph(model, {"evidence": evidence()})
        self.assertEqual((caught.exception.stage, caught.exception.issue, caught.exception.model_calls),
                         ("review", "review_dimensions", 4))
        self.assertEqual(model.calls, 4)

    async def test_wrong_enum_types_are_repaired_not_uncaught_type_errors(self):
        bad = coverage(); bad['coverage'] = ['uncovered']
        result, _ = await self.run_graph(Model([bad, coverage('uncertain', [])]), {'evidence': evidence()})
        self.assertEqual(result['coverage'], 'uncertain')
        for field in ('dimension', 'recommendation'):
            bad = review()
            if field == 'dimension':
                bad['checks'][0]['dimension'] = {'unexpected': 'mathematics'}
            else:
                bad['recommendation'] = ['ready_for_human']
            model = Model([coverage(), proposal(), bad, review()])
            result, execution = await self.run_graph(model, {'evidence': evidence()})
            self.assertEqual(result['status'], 'awaiting_human')
            self.assertEqual(execution['model_calls'], 4)

    async def test_discovery_without_exclusion_must_not_invent_boundary_evidence(self):
        items = evidence()[:3]
        draft = proposal(); draft['evidence_ids'] = [item['question_id'] for item in items]
        paused, _ = await self.run_graph(Model([coverage(), draft, review()]), {'evidence': items})
        self.assertEqual(paused['status'], 'awaiting_human')
        self.assertEqual(paused['review']['recommendation'], 'needs_revision')
        counterexample = next(item for item in paused['review']['checks'] if item['dimension'] == 'counterexamples')
        self.assertFalse(counterexample['passed'])
        self.assertEqual(paused['proposal']['evidence_ids'], draft['evidence_ids'])
        with self.assertRaisesRegex(SkillError, 'learningEvidence'):
            await self.run_graph(Model(), {'workflow_state': paused['workflow_state'],
                'decision': {'action': 'approve', 'reviewer': 'fixture', 'note': 'No exclusion provided'}})


if __name__ == "__main__": unittest.main()
