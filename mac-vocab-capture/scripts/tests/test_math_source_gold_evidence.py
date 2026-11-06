"""Independent source-answer checks; passing never grants teaching or rendering approval."""
import calendar
from collections import Counter
from copy import deepcopy
from fractions import Fraction as F
import importlib.util
from itertools import permutations
import json
from math import gcd
from pathlib import Path
import unittest

PACKAGE = Path(__file__).resolve().parents[2]
RESOURCES = PACKAGE / "Sources/VocabCapture/Resources"
FIXTURE_PATH = "Tests/VocabCaptureTests/Fixtures/MathDiagramDocumentCases.json"
SOURCE_SHA = "6886fcc09280e975b39667e70b678e7fd25efccfa637d5e6f45b28951d3f866a"
UNSUPPORTED = {"doc-13-01", "doc-21-01", "doc-25-01", "doc-26-01", "doc-27-01", "doc-28-01"}
QUARANTINED = {"doc-19-01", "doc-09-03", "doc-17-03", "doc-21-02", "doc-29-02"}
spec = importlib.util.spec_from_file_location("source_gold_audit", PACKAGE / "scripts/evaluate-math-teaching.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def independently_solve_supported():
    """Use the original numerical constraints, independent of plans and gold expressions."""
    solutions = {
        "doc-01-01": dict(rate=F(3, 5) / 5, newCost=F(3, 5) * F(16, 5)),
        "doc-02-01": dict(cloth=791 * F(16, 5), newCount=791 * F(16, 14)),
        "doc-03-01": dict(a=52, b=46, average=49, transfer=3),
        "doc-03-02": dict(length=10, width=8, area=80),
        "doc-04-01": dict(small=62, large=186),
        "doc-05-01": dict(small=62, large=186),
        "doc-06-01": dict(multiple=37, newOil=1480),
        "doc-07-01": dict(combined=49, time=8),
        "doc-08-01": dict(gap=900, relative=45, time=20),
        "doc-09-01": dict(intervals=68, trees=69),
        "doc-10-01": dict(nowRatio=7, nextFather=36, nextChild=6, nextRatio=6),
        "doc-11-01": dict(down=40, boat=25, up=10, upTime=32),
        "doc-12-01": dict(travel=2700, train=300),
        "doc-14-01": dict(children=12, apples=47),
        "doc-15-01": dict(product=150, sum=25, time=6),
        "doc-16-01": dict(total=3600, original=900, after=1200),
        "doc-17-01": dict(people=140, rate=4, treeA=188, treeB=192, treeC=180),
        "doc-18-01": dict(total=7200, usedPercent=10, leftPercent=90),
        "doc-19-02": dict(inflow=2, original=30, net=15, finalTime=2),
        "doc-20-01": dict(rabbit=12, chicken=23),
        "doc-22-01": dict(upFactor=F(11, 10), downFactor=F(9, 10), finalFactor=F(99, 100), percent=1),
        "doc-23-01": dict(interest=288, monthly=F(48, 5), months=30),
        "doc-24-01": dict(sugar=8, after=80, water=30, addedSugar=10, **{"doc-24-01-sugar:after": 60}),
        "doc-29-01": dict(totalFaces=6, rounds=3, totalTime=9),
        "doc-30-01": dict(a=50, b=40),
        "doc-31-01": dict(extraDesks=2, extraCost=240, deskRate=120, chairCost=30),
        "doc-07-02": dict(relative=8, travel=800, time=100, cycles=2, remaining=0),
    }
    return {identifier: {key: F(value) for key, value in values.items()} for identifier, values in solutions.items()}


def output_key(identifier, key):
    # Only the second concentration diagram has a distinct value with the same short id.
    if identifier == "doc-24-01" and key == "doc-24-01-sugar:after":
        return key
    return key.rsplit(":", 1)[-1]


def validate_geometry(witness):
    """Verify coordinates and every incidence, rather than trusting declared counts."""
    lines = {line["id"]: (F(line["slope"]), F(line["intercept"])) for line in witness["lines"]}
    if len(lines) != 5 or len(set(lines.values())) != 5:
        raise ValueError("five distinct straight rows required")
    points = [(F(point["x"]), F(point["y"])) for point in witness["points"]]
    if len(points) != 10 or len(set(points)) != 10:
        raise ValueError("ten distinct tree positions required")
    if len({point["id"] for point in witness["points"]}) != 10:
        raise ValueError("tree ids must be distinct")
    counts = Counter()
    for point, (x, y) in zip(witness["points"], points):
        actual_rows = {name for name, (slope, intercept) in lines.items() if y == slope * x + intercept}
        if len(actual_rows) != 2 or set(point["rows"]) != actual_rows or len(point["rows"]) != 2:
            raise ValueError("incorrect coordinate incidence")
        counts.update(actual_rows)
    if set(counts) != set(lines) or any(count != 4 for count in counts.values()):
        raise ValueError("each row must contain four trees")
    if witness["distinct_point_count"] != len(points) or witness["designated_row_counts"] != dict(counts):
        raise ValueError("declared geometry counts disagree with positions")
    return points, counts


def magic_solutions():
    # All 9! orders are examined: no center or symmetry assumption can hide solutions.
    solutions = set()
    for grid in permutations(range(1, 10)):
        if any(sum(grid[3 * row:3 * row + 3]) != 15 for row in range(3)):
            continue
        if any(sum(grid[column::3]) != 15 for column in range(3)):
            continue
        if grid[0] + grid[4] + grid[8] == grid[2] + grid[4] + grid[6] == 15:
            solutions.add(grid)
    return solutions


def validate_baking_schedule(witness):
    expected = {cake + face for cake in "ABC" for face in ("正", "反")}
    slots = witness["slots"]
    if witness["capacity"] != 2 or witness["slot_minutes"] != 3:
        raise ValueError("source capacity or duration changed")
    faces = []
    for slot in slots:
        if not 1 <= len(slot) <= 2 or len({face[0] for face in slot}) != len(slot):
            raise ValueError("capacity or simultaneous opposite faces invalid")
        faces.extend(slot)
    if len(faces) != 6 or set(faces) != expected:
        raise ValueError("every cake face must cook exactly once")
    # Six independent 3-minute faces require 18 face-minutes / capacity two.
    lower_bound = F(6 * 3, 2)
    if len(slots) * 3 != lower_bound:
        raise ValueError("schedule fails to attain capacity lower bound")
    return lower_bound


class SourceGoldEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures_doc = json.loads((PACKAGE / FIXTURE_PATH).read_text())
        cls.fixtures = {case["id"]: case for case in cls.fixtures_doc["cases"]}
        cls.inventory = {case["id"]: case for case in cls.fixtures_doc["inventory"]}
        cls.corpus = json.loads((RESOURCES / "MathTeachingReview/evaluation-corpus.json").read_text())
        cls.cases = {case["id"]: case for case in cls.corpus["cases"]}
        cls.solutions = independently_solve_supported()

    def source_case(self, identifier):
        return self.cases["handbook-" + identifier]

    def test_all_33_answers_bind_original_stems_and_source_without_approval(self):
        self.assertEqual(self.fixtures_doc["source"]["sha256"], SOURCE_SHA)
        self.assertEqual(self.corpus["handbook_sha256"], SOURCE_SHA)
        examples = [case for case in self.cases.values() if case["kind"] == "source_example"]
        self.assertEqual({case["source"]["case_id"] for case in examples}, set(self.solutions) | UNSUPPORTED)
        for case in examples:
            identifier = case["source"]["case_id"]
            with self.subTest(case=identifier):
                fixture = self.fixtures[identifier]
                self.assertEqual(case["stem"], fixture["stem"])
                self.assertEqual(case["stem"], self.inventory[identifier]["stem"])
                self.assertEqual(case["source"]["sha256"], SOURCE_SHA)
                self.assertEqual(case["source"]["locator"], fixture["sourceLocator"])
                self.assertEqual(case["gold_evidence"]["source"], case["source"])
                self.assertEqual(case["gold_evidence"]["existing_fixture_binding"], {"file": FIXTURE_PATH, "case_id": identifier})
                self.assertFalse(case["gold_evidence"]["human_approval_granted"])
                self.assertNotEqual(case["review_status"], "approved")
                self.assertTrue(case["reference_answer"])
                self.assertTrue(case["gold_checks"])
                for check in case["gold_checks"]:
                    audit.verify_gold(check)

    def test_all_supported_fixture_outputs_match_independent_answers(self):
        supported = {identifier for identifier, fixture in self.fixtures.items() if fixture["status"] == "supported"}
        self.assertEqual(supported, set(self.solutions))
        for identifier, solved in self.solutions.items():
            with self.subTest(case=identifier):
                fixture_outputs = self.fixtures[identifier]["expected"]["values"]
                checked_keys = set()
                for key, value in fixture_outputs.items():
                    normalized = output_key(identifier, key)
                    self.assertIn(normalized, solved)
                    self.assertEqual(F(str(value)), solved[normalized])
                    checked_keys.add(normalized)
                self.assertEqual(checked_keys, set(solved))
                independent = self.source_case(identifier)["gold_evidence"]["independent_values"]
                self.assertEqual({key: F(value) for key, value in independent.items()}, solved)

    def test_answers_satisfy_original_constraints_not_only_gold_expressions(self):
        s = self.solutions
        self.assertEqual(s["doc-01-01"]["rate"] * 5, F(3, 5))
        self.assertEqual(s["doc-02-01"]["newCount"] * F(14, 5), 791 * F(16, 5))
        self.assertEqual((s["doc-03-01"]["a"] + s["doc-03-01"]["b"], s["doc-03-01"]["a"] - s["doc-03-01"]["b"]), (98, 6))
        self.assertEqual((s["doc-03-02"]["length"] + s["doc-03-02"]["width"], s["doc-03-02"]["length"] - s["doc-03-02"]["width"]), (18, 2))
        self.assertEqual(s["doc-03-02"]["length"] * s["doc-03-02"]["width"], s["doc-03-02"]["area"])
        self.assertEqual(s["doc-04-01"]["large"] + s["doc-04-01"]["small"], 248)
        for identifier in ("doc-04-01", "doc-05-01"):
            self.assertEqual(s[identifier]["large"], 3 * s[identifier]["small"])
        self.assertEqual(s["doc-05-01"]["large"] - s["doc-05-01"]["small"], 124)
        self.assertEqual(s["doc-06-01"]["newOil"] * 100, 3700 * 40)
        self.assertEqual(s["doc-07-01"]["time"] * (28 + 21), 392)
        self.assertEqual(s["doc-08-01"]["time"] * 120, (12 + s["doc-08-01"]["time"]) * 75)
        self.assertEqual((s["doc-09-01"]["trees"] - 1) * 2, 136)
        self.assertEqual((35 / s["doc-10-01"]["nowRatio"], 36 / s["doc-10-01"]["nextRatio"]), (5, 6))
        self.assertEqual((s["doc-11-01"]["boat"] + 15) * 8, 320)
        self.assertEqual((s["doc-11-01"]["boat"] - 15) * s["doc-11-01"]["upTime"], 320)
        self.assertEqual(900 * 3 - 2400, s["doc-12-01"]["train"])
        self.assertEqual(s["doc-14-01"]["apples"] - 3 * s["doc-14-01"]["children"], 11)
        self.assertEqual(4 * s["doc-14-01"]["children"] - s["doc-14-01"]["apples"], 1)
        self.assertEqual(s["doc-15-01"]["time"] * (F(1, 10) + F(1, 15)), 1)
        self.assertEqual(s["doc-16-01"]["original"] * 3, s["doc-16-01"]["total"] - s["doc-16-01"]["original"])
        self.assertEqual(s["doc-16-01"]["after"], s["doc-16-01"]["original"] + 300)
        self.assertEqual(s["doc-16-01"]["after"] * 2, s["doc-16-01"]["total"] - s["doc-16-01"]["after"])
        allocations = [s["doc-17-01"][key] for key in ("treeA", "treeB", "treeC")]
        self.assertEqual(sum(allocations), 560)
        self.assertEqual([amount / people for amount, people in zip(allocations, (47, 48, 45))], [4] * 3)
        self.assertEqual((s["doc-18-01"]["total"] * s["doc-18-01"]["usedPercent"] / 100, s["doc-18-01"]["total"] * s["doc-18-01"]["leftPercent"] / 100), (720, 6480))
        for people, hours in ((12, 3), (5, 10), (17, s["doc-19-02"]["finalTime"])):
            self.assertEqual((people - s["doc-19-02"]["inflow"]) * hours, s["doc-19-02"]["original"])
        self.assertEqual((s["doc-20-01"]["rabbit"] + s["doc-20-01"]["chicken"], 4 * s["doc-20-01"]["rabbit"] + 2 * s["doc-20-01"]["chicken"]), (35, 94))
        self.assertEqual(s["doc-22-01"]["upFactor"] * s["doc-22-01"]["downFactor"], s["doc-22-01"]["finalFactor"])
        self.assertEqual((1 - s["doc-22-01"]["finalFactor"]) * 100, s["doc-22-01"]["percent"])
        self.assertEqual(1200 * F(8, 1000) * s["doc-23-01"]["months"] + 1200, 1488)
        self.assertEqual(s["doc-24-01"]["sugar"] / (50 + s["doc-24-01"]["water"]), F(1, 10))
        self.assertEqual((s["doc-24-01"]["sugar"] + s["doc-24-01"]["addedSugar"]) / (50 + s["doc-24-01"]["addedSugar"]), F(3, 10))
        self.assertEqual((s["doc-30-01"]["a"] + s["doc-30-01"]["b"], 2 * s["doc-30-01"]["b"] - s["doc-30-01"]["a"]), (90, 30))
        self.assertEqual((4 * s["doc-31-01"]["deskRate"] + s["doc-31-01"]["chairCost"], 6 * s["doc-31-01"]["deskRate"] + s["doc-31-01"]["chairCost"]), (510, 750))
        t = s["doc-07-02"]["time"]
        self.assertEqual((5 * t + 3 * t) / 400, 2)
        self.assertEqual((5 * t) % 400, (-3 * t) % 400)

    def test_unsupported_rendering_and_quarantined_sources_remain_unapproved(self):
        self.assertEqual({key for key, case in self.fixtures.items() if case["status"] == "unsupported"}, UNSUPPORTED)
        self.assertEqual({key for key, case in self.fixtures.items() if case["status"] == "quarantined"}, QUARANTINED)
        for identifier in UNSUPPORTED:
            case = self.source_case(identifier)
            self.assertEqual(case["source_status"], "unsupported")
            self.assertEqual(case["gold_evidence"]["existing_fixture_status"], "unsupported")
            self.assertTrue(case["gold_evidence"]["limitations"])
        for identifier in QUARANTINED:
            case = self.source_case(identifier)
            self.assertEqual(case["kind"], "source_quarantine")
            self.assertEqual(case["review_status"], "quarantined")
            self.assertEqual(case["source_status"], "quarantined")
            self.assertEqual(case["gold_checks"], [])
            self.assertNotIn("gold_evidence", case)
            self.assertTrue(case["limitations"])

    def test_clock_exact_overlap_and_square_count_do_not_imply_renderer_support(self):
        clock = self.source_case("doc-13-01")["gold_evidence"]["independent_values"]
        t = F(clock["time"])
        self.assertEqual(t, 20 + t / 12)
        self.assertNotEqual(t, 22)
        square = self.source_case("doc-21-01")["gold_evidence"]["independent_values"]
        self.assertEqual(F(square["count"]), F(square["rows"]) ** 2)
        self.assertEqual(F(square["rows"]), 22)

    def test_geometry_witness_full_incidence_and_invalid_positions(self):
        witness = self.source_case("doc-25-01")["gold_evidence"]["constraint_witness"]
        self.assertEqual(witness["kind"], "existence_only_non_unique")
        validate_geometry(witness)
        for mutation in ("coordinate", "duplicate", "incidence", "line"):
            bad = deepcopy(witness)
            if mutation == "coordinate": bad["points"][0]["y"] = "17"
            elif mutation == "duplicate": bad["points"][0].update(x=bad["points"][1]["x"], y=bad["points"][1]["y"])
            elif mutation == "incidence": bad["points"][0]["rows"] = ["row-0", "row-2"]
            else: bad["lines"][0]["intercept"] = 17
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): validate_geometry(bad)

    def test_magic_square_all_9_factorial_orders_have_eight_full_solutions(self):
        witness = self.source_case("doc-26-01")["gold_evidence"]["constraint_witness"]
        solutions = magic_solutions()
        self.assertEqual(len(solutions), 8)
        self.assertEqual(witness["exact_solution_count"], len(solutions))
        grid = witness["grid"]
        self.assertIn(tuple(value for row in grid for value in row), solutions)
        self.assertEqual(witness["kind"], "existence_only_non_unique")
        for solution in solutions:
            audit.verify_gold({"kind": "magic_square", "grid": [list(solution[i:i + 3]) for i in (0, 3, 6)], "expected": 15})
        bad = deepcopy(grid)
        bad[0][0], bad[0][1] = bad[0][1], bad[0][0]
        with self.assertRaises(ValueError): audit.verify_gold({"kind": "magic_square", "grid": bad, "expected": 15})

    def test_leap_year_birthday_bound_is_sharp_not_365_day_assumption(self):
        witness = self.source_case("doc-27-01")["gold_evidence"]["constraint_witness"]
        days = sum(calendar.monthrange(2000, month)[1] for month in range(1, 13))
        self.assertTrue(calendar.isleap(2000))
        self.assertEqual(days, witness["date_slots"])
        people = witness["people"]
        self.assertEqual(people, 367)
        histogram = witness["occupancy_histogram"]
        self.assertEqual(histogram["one_person_dates"] + histogram["two_person_dates"], days)
        self.assertEqual(histogram["one_person_dates"] + 2 * histogram["two_person_dates"], people)
        self.assertEqual(histogram["two_person_dates"], 1)
        self.assertLess(days, people)
        self.assertEqual(max([1] * histogram["one_person_dates"] + [2] * histogram["two_person_dates"]), 2)

    def test_cutting_side_is_maximal_and_covers_whole_board(self):
        evidence = self.source_case("doc-28-01")["gold_evidence"]
        values = {key: F(value) for key, value in evidence["independent_values"].items()}
        divisors = [value for value in range(1, 57) if 60 % value == 56 % value == 0]
        self.assertEqual(divisors, evidence["constraint_witness"]["positive_integer_common_divisors"])
        self.assertEqual(values["side"], max(divisors))
        self.assertEqual(values["side"], gcd(60, 56))
        self.assertEqual(values["columns"] * values["side"], 60)
        self.assertEqual(values["rows"] * values["side"], 56)
        self.assertEqual(values["squares"] * values["side"] ** 2, 60 * 56)

    def test_baking_schedule_attains_lower_bound_without_baking_both_faces_together(self):
        witness = self.source_case("doc-29-01")["gold_evidence"]["constraint_witness"]
        self.assertEqual(validate_baking_schedule(witness), 9)
        for slots in ([["A正", "A反"], ["B正", "C正"], ["B反", "C反"]], [["A正", "B正", "C正"], ["A反", "B反", "C反"]], [["A正", "B正"], ["A反", "C正"], ["B反", "C正"]]):
            bad = deepcopy(witness)
            bad["slots"] = slots
            with self.assertRaises(ValueError): validate_baking_schedule(bad)


if __name__ == "__main__":
    unittest.main()
