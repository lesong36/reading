"""Independent integer exchange oracle and source binding for bottle-exchange v2.

These checks validate the skill's mathematical contract, not model compliance.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bottle_skill_validator", SCRIPTS / "validate-math-skills.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def reachable_maximum(initial_empty, exchange_cost, allow_borrow=False):
    """Enumerate legal exchanges and optional one-bottle credit, requiring repayment.

    No division/net-consumption formula is used in this oracle. Credit may be
    taken at any time, and is counted as debt until an actual bottle is returned.
    """
    initial = (initial_empty, 0, 0)
    pending, seen = [initial], {initial}
    while pending:
        empty, debt, drinks = pending.pop()
        next_states = []
        if empty >= exchange_cost:
            # Hand over exchange_cost actual empties, then drink one full bottle.
            next_states.append((empty - exchange_cost + 1, debt, drinks + 1))
        if allow_borrow and debt == 0:
            next_states.append((empty + 1, 1, drinks))
        if debt == 1 and empty >= 1:
            next_states.append((empty - 1, 0, drinks))
        for state in next_states:
            if state not in seen:
                seen.add(state)
                pending.append(state)
    paid = [state for state in seen if state[1] == 0]
    maximum = max(state[2] for state in paid)
    return maximum, {state[0] for state in paid if state[2] == maximum}


class BottleExchangeAssetTests(unittest.TestCase):
    def setUp(self):
        self.root = SCRIPTS.parent / "Sources/VocabCapture/Resources"
        self.skill = self.root / "MathSkills/bottle-exchange/SKILL.md"
        self.top, self.metadata, self.body_bytes = validator.parse_skill(self.skill.read_bytes())
        self.body = self.body_bytes.decode()

    def test_source_identity_and_revision_bind_manifest_and_unapproved_profile(self):
        self.assertEqual(validator.validate(self.root / "MathSkills"), 49)
        source = self.skill.parent / "references/source.md"
        original_hash = "26c624ec0af5c63a061db7b6895f53d54c87bdce8269fa97e3b25c6819886e2a"
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), original_hash)
        self.assertEqual(self.metadata["source_sha256"], original_hash)
        self.assertEqual(self.metadata["legacy_source_id"],
                         "markdown-7fcb64fbf20fff6f0a128e1dac6a16065124fbc7beeaa339686b75cdb3725a20")
        self.assertEqual(self.metadata["version"], "2")
        self.assertEqual(self.metadata["body_sha256"], hashlib.sha256(self.body_bytes).hexdigest())
        manifest = json.loads((self.root / "MathSkills/index.json").read_text())
        entry = next(row for row in manifest["skills"] if row["name"] == "bottle-exchange")
        profile = next(row for row in json.loads((self.root / "MathTeachingReview/profiles.json").read_text())["profiles"]
                       if row["skill_name"] == "bottle-exchange")
        self.assertEqual(entry["version"], "2")
        self.assertEqual(entry["sha256"], hashlib.sha256(self.skill.read_bytes()).hexdigest())
        self.assertEqual(profile["skill_sha256"], entry["sha256"])
        self.assertEqual(profile["skill_version"], entry["version"])
        self.assertEqual(profile["applicable_when"], [self.top["description"]])
        self.assertEqual(profile["review_status"], "review_required")
        reference = next(row for row in profile["source_references"] if row["locator"] == entry["path"])
        self.assertEqual(reference["sha256"], entry["sha256"])

    def test_actual_skill_no_borrow_formula_matches_independent_legal_state_enumeration(self):
        self.assertIn("新增可喝瓶数 = floor((m−1)/(n−1))", self.body)
        self.assertIn("初始空瓶m=0时，新增可喝瓶数为0", self.body)
        self.assertIn("未明确允许临时借瓶时，按不借瓶处理", self.body)
        for cost in range(2, 11):
            for empty in range(41):
                with self.subTest(cost=cost, initial_empty=empty):
                    actual, leftovers = reachable_maximum(empty, cost)
                    self.assertEqual(actual, (empty - 1) // (cost - 1) if empty else 0)
                    self.assertEqual(leftovers, {empty - actual * (cost - 1)})

    def test_borrow_branch_requires_zero_debt_and_is_distinct_from_no_borrow(self):
        self.assertIn("只有题目明确允许借瓶且能归还时", self.body)
        self.assertIn("新增可喝瓶数 = floor(m/(n−1))", self.body)
        self.assertIn("不能把这个公式用于不借瓶情形", self.body)
        for cost in range(2, 11):
            for empty in range(41):
                with self.subTest(cost=cost, initial_empty=empty):
                    drinks, leftovers = reachable_maximum(empty, cost, allow_borrow=True)
                    self.assertEqual(drinks, empty // (cost - 1))
                    self.assertEqual(leftovers, {empty - drinks * (cost - 1)})
        self.assertEqual(reachable_maximum(10, 3), (4, {2}))
        self.assertEqual(reachable_maximum(10, 3, True), (5, {0}))
        self.assertEqual(reachable_maximum(2, 3), (0, {2}))
        self.assertEqual(reachable_maximum(2, 3, True), (1, {0}))
        self.assertEqual(reachable_maximum(5, 2), (4, {1}))

    def test_frozen_transfer_gold_remains_fourteen_and_skill_distinguishes_full_from_empty(self):
        corpus = json.loads((self.root / "MathTeachingReview/evaluation-corpus.json").read_text())
        case = next(row for row in corpus["cases"] if row["id"] == "transfer-bottle-exchange")
        self.assertIn("14", [str(check["expected"]) for check in case["gold_checks"]])
        extra, leftovers = reachable_maximum(10, 3)
        self.assertEqual(10 + extra, 14)
        self.assertEqual(leftovers, {2})
        self.assertIn("先喝完这m瓶", self.body)
        self.assertIn("初始只有m个空瓶", self.body)
        self.assertIn("兑换所得就是新增饮用量，不加m", self.body)
        self.assertIn("空瓶10→8→6→4→2", self.body)
        self.assertIn("共14瓶，剩2个空瓶", self.body)
        self.assertIn("合计15瓶，余瓶0、欠瓶0", self.body)


if __name__ == "__main__":
    unittest.main()
