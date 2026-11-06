"""Independent layout checks for the two corrected, source-preserving skills."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("boundary_skill_validator", SCRIPTS / "validate-math-skills.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
spec = importlib.util.spec_from_file_location("boundary_teaching_audit", SCRIPTS / "evaluate-math-teaching.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class MathSkillBoundaryAssetTests(unittest.TestCase):
    def setUp(self):
        self.root = SCRIPTS.parent / "Sources/VocabCapture/Resources"
        self.corpus = json.loads((self.root / "MathTeachingReview/evaluation-corpus.json").read_text())
        self.cases = {case["id"]: case for case in self.corpus["cases"]}

    def test_original_failed_labels_and_numeric_gold_are_unchanged(self):
        identities = {"boundary-nondivisible-loop", "boundary-square-ambiguous",
                      "transfer-intervals-and-endpoints", "transfer-square-arrangements"}
        original = [case for case in self.corpus["cases"] if case["id"] in identities]
        data = json.dumps(original, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        self.assertEqual(hashlib.sha256(data).hexdigest(),
                         "6f4ea3d2266bce73126482ab893bd9d5c7fc4b1ba83625eb18f6ba1f2b90373d")

    def test_revision_and_original_sources_bind_the_catalogue_and_profiles(self):
        self.assertEqual(validator.validate(self.root / "MathSkills"), 49)
        index = json.loads((self.root / "MathSkills/index.json").read_text())
        profiles = json.loads((self.root / "MathTeachingReview/profiles.json").read_text())
        originals = {"intervals-and-endpoints": "9a7a1aac8283b3085994308ade7f04c3f7559f133a980720f48918f02a45db65",
                     "square-arrangements": "27e031d3f1823f1d3418c44a0af18a0df9c159fcbd870e490ef89ae970603b61"}
        for name, digest in originals.items():
            entry = next(row for row in index["skills"] if row["name"] == name)
            profile = next(row for row in profiles["profiles"] if row["skill_name"] == name)
            source = self.root / "MathSkills" / name / "references/source.md"
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), digest)
            self.assertEqual(entry["version"], "2")
            self.assertEqual(profile["skill_version"], entry["version"])
            self.assertEqual(profile["skill_sha256"], entry["sha256"])
            self.assertNotEqual(profile["review_status"], "approved")

    def test_changed_original_or_corrected_body_cannot_hide_behind_manifest_rehash(self):
        for name in ("intervals-and-endpoints", "square-arrangements"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "MathSkills"
                shutil.copytree(self.root / "MathSkills", root)
                source = root / name / "references/source.md"
                original = source.read_bytes()
                source.write_bytes(original + b"\nAltered source\n")
                with self.assertRaisesRegex(validator.ValidationError, "source digest mismatch"):
                    validator.validate(root)
                source.write_bytes(original)
                skill = root / name / "SKILL.md"
                skill.write_bytes(skill.read_bytes() + b"\nAltered correction\n")
                manifest = json.loads((root / "index.json").read_text())
                entry = next(row for row in manifest["skills"] if row["name"] == name)
                entry["sha256"] = hashlib.sha256(skill.read_bytes()).hexdigest()
                (root / "index.json").write_text(json.dumps(manifest))
                with self.assertRaisesRegex(validator.ValidationError, "body digest mismatch"):
                    validator.validate(root)

    def gold_expected(self, identity, position):
        case = self.cases[identity]
        for check in case["gold_checks"]:
            audit.verify_gold(check)
        return audit.exact(case["gold_checks"][position]["expected"])

    def test_closed_loop_corner_constraints_use_actual_positions_not_only_perimeter(self):
        side, spacing = 176, 8
        positions = set(range(0, 4 * side, spacing))
        self.assertTrue({0, side, 2 * side, 3 * side} <= positions)
        self.assertEqual(len(positions), self.gold_expected("companion-corner-loop-valid", 1))
        inconsistent_side = 178
        inconsistent_positions = set(range(0, 4 * inconsistent_side, spacing))
        # A closed ring can fit89 equally spaced lights, but not all4 required corners.
        self.assertEqual((4 * inconsistent_side) % spacing, 0)
        self.assertFalse({0, inconsistent_side, 2 * inconsistent_side, 3 * inconsistent_side}
                         <= inconsistent_positions)
        invalid = self.cases["companion-corner-loop-inconsistent"]
        self.assertEqual(invalid["expected_methods"], [])
        self.assertIn("intervals-and-endpoints", invalid["forbidden_methods"])
        self.assertEqual(self.gold_expected(invalid["id"], 0), 2)

    @staticmethod
    def occupied_cells(edge, layers):
        return {(x, y) for x in range(edge) for y in range(edge)
                if min(x, y, edge - 1 - x, edge - 1 - y) < layers}

    def test_square_gold_matches_independent_grid_enumeration_and_empty_hole(self):
        occupied = self.occupied_cells(10, 3)
        outer = self.occupied_cells(10, 1)
        self.assertEqual(len(outer), 36)
        self.assertEqual(len(occupied), self.gold_expected("companion-square-outer-ring-valid", 1))
        occupied = self.occupied_cells(14, 4)
        inner_occupied_ring = occupied - self.occupied_cells(14, 3)
        hole = {(x, y) for x in range(14) for y in range(14)} - occupied
        self.assertEqual(len(inner_occupied_ring), 28)
        self.assertEqual(len({x for x, y in inner_occupied_ring}),
                         self.gold_expected("companion-square-inner-ring-valid", 0))
        self.assertEqual(len({x for x, y in hole}),
                         self.gold_expected("companion-square-inner-ring-valid", 1))
        self.assertEqual(len(occupied), self.gold_expected("companion-square-inner-ring-valid", 2))

    def test_invalid_outer_count_and_excess_layers_do_not_create_numeric_count_answers(self):
        self.assertFalse(any(len(self.occupied_cells(edge, 1)) == 14 for edge in range(2, 100)))
        self.assertEqual(len(self.occupied_cells(5, 4)), 25)
        self.assertFalse({(x, y) for x in range(5) for y in range(5)} - self.occupied_cells(5, 4))
        for identity in ("companion-square-outer-ring-inconsistent", "companion-square-too-many-layers"):
            case = self.cases[identity]
            self.assertEqual(case["expected_methods"], [])
            self.assertIn("square-arrangements", case["forbidden_methods"])
            self.assertTrue(case["limitations"])
            self.gold_expected(identity, 0)


if __name__ == "__main__":
    unittest.main()
