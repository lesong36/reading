"""Scripted checks of real bundled body provenance, not model selection accuracy."""
import hashlib
import json
import os
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import HumanMessage, SystemMessage
from math_skills import SkillError, SnapshotBackend, select_skills, snapshots_for
from test_math_skills import ScriptModel, declared_policy
from test_math_tool_strategy import decision, read, truth_decision
from test_math_prerequisite_scope import draft, reviewed

ROOT = Path(os.environ.get("MATH_SKILLS_SOURCE_ROOT", str(Path(__file__).resolve().parents[2] / "Sources/VocabCapture/Resources/MathSkills")))


def body(name):
    text = (ROOT / name / "SKILL.md").read_text()
    return text.split("\n---\n", 1)[1]


# branch, other conditional rule, trigger, consequent, proposition, actual original facts.
CASES = [
    ("overlap-counting", "union", "先加再减", "知道总数和两部分，求重叠：\n\n$$\\text{重叠} = A + B - \\text{总数}$$", "知道总数和两部分，求重叠", "\\text{重叠} = A + B - \\text{总数}", "本题已知总数和两部分且要求重叠数", "数学组30人，语文组25人，两组都参加的10人，求至少参加一组的人数。"),
    ("overlap-counting", "intersection", "知道总数和两部分，求重叠：", "$$A \\cup B = A + B - A \\cap B$$", "A \\cup B", "A + B - A \\cap B", "本题要求参加至少一组的并集人数", "数学组30人，语文组25人，至少参加一组的共有45人，求两组都参加的人数。"),
    ("intervals-and-endpoints", "stairs", "从1楼到8楼实际有8−1=7个楼层间隔。", "一根木头锯成5段，切口不在两头，刀数为5−1=4；必须确认一次一刀、没有叠放等改变切割规则的条件。", "一根木头锯成5段", "必须确认一次一刀、没有叠放等改变切割规则的条件", "本题正在将一根木头锯成若干段", "从1楼到14楼，每个楼层间21级台阶，求总台阶数。"),
    ("intervals-and-endpoints", "wood", "一根木头锯成5段，切口不在两头，刀数为5−1=4；", "从1楼到8楼实际有8−1=7个楼层间隔。每层间的台阶数乘7得到总台阶数，不把出发楼层自身算一段。", "从1楼到8楼", "每层间的台阶数乘7得到总台阶数", "本题正在跨楼层数台阶", "一根木头锯成7段，切口不在两头，一次一刀，不叠放，求刀数。"),
    ("direct-inverse-proportion", "direct", "对应的两个数相除，商始终不变，就是正比例。", "对应的两个数相乘，积始终不变，就是反比例。", "对应的两个数相乘", "积始终不变", "本题两种量的乘积始终不变", "每分钟做题数不变，4道题用28分钟，求91分钟的题数。"),
    ("direct-inverse-proportion", "inverse", "对应的两个数相乘，积始终不变，就是反比例。", "对应的两个数相除，商始终不变，就是正比例。", "对应的两个数相除", "商始终不变", "本题两种量的商始终不变", "一本书总页数不变，每天24页读15天，改成每天36页，求天数。"),
    ("product-area-diagram", "direct-product", "两个量相乘，画成矩形的面积，或者画成一条被等分的线段。", "已知面积和一条边，未知边等于面积除以已知边。", "已知面积和一条边", "未知边等于面积除以已知边", "本题已知总量和一个因子且要求另一个未知因子", "每盒牛奶18元，买3盒，求总价。"),
    ("product-area-diagram", "inverse-edge", "已知面积和一条边，未知边等于面积除以已知边。", "$$\\text{总价} = \\text{单价} \\times \\text{数量}$$", "\\text{总价}", "\\text{单价} \\times \\text{数量}", "本题要求用已知单价和数量求总价", "买4支钢笔花32元，求每支单价。"),
    ("redistribution-balance", "two", "两人时，移动量等于差的一半。", "多人时，最后每人等于总数除以人数。", "多人时", "最后每人等于总数除以人数", "本题平衡分配涉及多人", "只有小熊和狐狸两人，分别10颗和4颗糖，求移动多少颗使两人一样多。"),
    ("redistribution-balance", "many", "多人时，最后每人等于总数除以人数。", "两人时，移动量等于差的一半。", "两人时", "移动量等于差的一半", "本题只有两人需要平衡", "三人分别8颗、4颗、6颗糖，求怎样移动使三人一样多。"),
]


class BuiltinBranchContractTests(unittest.IsolatedAsyncioTestCase):
    async def check_case(self, case, *, active):
        name, kind, branch, rule, trigger, consequent, proposition, original = case
        if active:
            index = CASES.index(case)
            original = CASES[index + 1 if index % 2 == 0 else index - 1][-1]
            branch = rule
        instructions = body(name)
        # Assertions lock the actual source quotes; no trimmed/generated paraphrase is substituted.
        self.assertIn(branch, instructions)
        self.assertIn(rule, instructions)
        self.assertIn(trigger, rule)
        self.assertIn(consequent, rule)
        identifier = name
        row = {"id": identifier, "version_id": hashlib.sha256(instructions.encode()).hexdigest(), "title": name,
            "category": "来源正文协议测试", "instructions": instructions}
        row["teaching_policy"] = declared_policy(row)
        snapshots = snapshots_for([row])
        additional = {"requirement": "仅在所引其他分支触发时所需的前提", "skill_excerpt": consequent,
            "proposition": "原题给出本分支所需事实", "basis": "fact", "arithmetic": None, "truth": None, "evidence": "原题没有要求此分支的数量关系", "scope": "required" if active else "not_current_branch",
            "guard_excerpt": rule, "guard_trigger_excerpt": trigger, "guard_proposition": proposition,
            "guard_truth": active, "guard_evidence": ("测试原题明确触发所引分支：" if active else "原题属于另一分支：") + original}
        value = reviewed(identifier=identifier, branch=branch, extras=[additional])
        model = ScriptModel(); model._responses = [read(next(iter(SnapshotBackend(snapshots).files))), decision(draft(identifier)), truth_decision(value)]
        if active:
            with self.assertRaises(SkillError) as captured:
                await select_skills(model, [SystemMessage("仅查方法"), HumanMessage(original)], snapshots)
            self.assertEqual(captured.exception.code, "skillsPrerequisite")
            self.assertEqual(captured.exception.details["prerequisite_review"]["status"], "blocked")
        else:
            raw, details = await select_skills(model, [SystemMessage("仅查方法"), HumanMessage(original)], snapshots)
            self.assertEqual(json.loads(raw), draft(identifier))
            self.assertEqual(details["prerequisite_review"]["status"], "passed")
            self.assertIsNone(details["prerequisite_review"]["result"]["methods"][0]["additional_prerequisites"][0]["truth"])
        self.assertEqual(len(model._calls), 3)
        self.assertIn(instructions, json.loads(model._calls[-1][0].text.split("完整方法版本：\n", 1)[1].split("\n待检查肯定命题", 1)[0])[0]["instructions"])

    async def test_actual_five_builtin_sources_both_directions_preserve_excluded_unknown(self):
        for case in CASES:
            with self.subTest(skill=case[0], branch=case[1]):
                await self.check_case(case, active=False)

    async def test_same_real_source_quotes_cannot_waive_active_unknown(self):
        for case in CASES:
            with self.subTest(skill=case[0], branch=case[1]):
                # Use the other case of this same skill pair as the original input.
                # The judgments remain scripted; no real model correctness is asserted.
                await self.check_case(case, active=True)


if __name__ == "__main__": unittest.main()
