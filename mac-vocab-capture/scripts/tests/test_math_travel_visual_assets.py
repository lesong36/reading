"""Source preservation and binding checks for the useful-diagram routing revision."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("travel_skill_validator", SCRIPTS / "validate-math-skills.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class TravelVisualAssetTests(unittest.TestCase):
    def setUp(self):
        self.root = SCRIPTS.parent / "Sources/VocabCapture/Resources"

    def test_original_user_methods_preserved_as_sources_of_new_versions(self):
        originals = {
            "product-area-diagram": "9206895fa5c391ff496ed3a22d7663170f8b36e08490629eefb785e7bce0e555",
            "distance-speed-time": "fcdce0a5f3bc3d723ad1d6988eec32f285228548be473c50d73c9562fa992d37",
            "comparison-line-diagram": "62385ba4658c59a33e014a25a9d6c8394d127d59239a5a64b50d01213362fc0c",
            "hypothesis-table-diagram": "925cac3b79d9270d76e2308d6d80d02cff3166558fb7bec0c8a2634455d5681a",
            "math-diagram-routing": "a871414345776aae4c486b45c843d2739e0b4f7d4f642e5897544ba1d717f26b",
        }
        self.assertEqual(validator.validate(self.root / "MathSkills"), 49)
        index = {v["name"]: v for v in json.loads((self.root / "MathSkills/index.json").read_text())["skills"]}
        profiles = {v["skill_name"]: v for v in json.loads((self.root / "MathTeachingReview/profiles.json").read_text())["profiles"]}
        for name, digest in originals.items():
            with self.subTest(skill=name):
                directory = self.root / "MathSkills" / name
                self.assertEqual(hashlib.sha256((directory / "references/source.md").read_bytes()).hexdigest(), digest)
                entry, profile = index[name], profiles[name]
                self.assertEqual(entry["version"], "2")
                self.assertEqual(profile["skill_version"], entry["version"])
                self.assertEqual(profile["skill_sha256"], entry["sha256"])
                self.assertEqual(profile["applicable_when"], [entry["description"]])
                reference = next(v for v in profile["source_references"] if v["locator"] == name + "/SKILL.md")
                self.assertEqual(reference["sha256"], entry["sha256"])
                self.assertNotEqual(profile["review_status"], "approved")

    def test_revision_does_not_change_historical_numeric_or_visual_evaluation_gold(self):
        corpus = (self.root / "MathTeachingReview/evaluation-corpus.json").read_bytes()
        self.assertEqual(hashlib.sha256(corpus).hexdigest(),
                         "a0e3a887c08878527e33a5f235511e3bd1906ff263b6f348142357e0f60cacfb")

    def test_visual_revision_keeps_solution_visual_and_router_roles_separate(self):
        profiles = {v["skill_name"]: v for v in json.loads((self.root / "MathTeachingReview/profiles.json").read_text())["profiles"]}
        expected = {"distance-speed-time": ["solution"], "math-diagram-routing": ["routing"],
                    "hypothesis-table-diagram": ["visual"], "comparison-line-diagram": ["visual"],
                    "product-area-diagram": ["visual"]}
        for name, roles in expected.items():
            with self.subTest(skill=name):
                self.assertEqual(profiles[name]["selection_roles"], roles)


if __name__ == "__main__":
    unittest.main()
